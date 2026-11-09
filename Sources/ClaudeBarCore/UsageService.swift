import Foundation
import os

/// The credentials + network boundary as a single actor, so the view-model can just
/// `await fetch()` without worrying about Keychain access happening off-main.
public actor UsageService {
    /// Which credential actually served a successful fetch — surfaced for logging.
    public enum TokenSource: String, Sendable {
        case selfContained
        case claudeCode
    }

    private let loadSelfContained: @Sendable () -> OAuthTokens?
    private let selfContainedToken: @Sendable () async throws -> String?
    private let claudeCodeToken: @Sendable () async -> String?
    /// Clears our sign-in only if the given access token is still the stored one, and says
    /// whether it did: false means a newer sign-in replaced it.
    private let clearSelfContained: @Sendable (String) async -> Bool
    private let fetchUsage: @Sendable (String) async throws -> UsageResponse
    /// Shared by the usage poll and the account-offers fetch, which can ask at the same
    /// moment: each refresh spends our single-use refresh token, so they must not both refresh.
    private let tokenFlight = SingleFlight<String?>()
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "UsageService")
    /// Only for log lines, so a poll of two accounts says which one it served.
    private let accountID: String

    public init(account: ClaudeAccount = .standard()) {
        let store = SelfContainedCredentialStore(account: account)
        let credentials = CredentialsProvider(account: account)
        let client = UsageClient()
        self.init(
            accountID: account.id,
            loadSelfContained: { store.load() },
            selfContainedToken: { try await store.validAccessToken() },
            claudeCodeToken: { credentials.loadAccessToken() },
            clearSelfContained: { store.clear(ifAccessToken: $0) },
            fetchUsage: { try await client.fetchUsage(token: $0) }
        )
    }

    init(
        accountID: String = ClaudeAccount.defaultID,
        loadSelfContained: @escaping @Sendable () -> OAuthTokens? = { nil },
        selfContainedToken: @escaping @Sendable () async throws -> String?,
        claudeCodeToken: @escaping @Sendable () async -> String?,
        clearSelfContained: @escaping @Sendable (String) async -> Bool,
        fetchUsage: @escaping @Sendable (String) async throws -> UsageResponse
    ) {
        self.accountID = accountID
        self.loadSelfContained = loadSelfContained
        self.selfContainedToken = selfContainedToken
        self.claudeCodeToken = claudeCodeToken
        self.clearSelfContained = clearSelfContained
        self.fetchUsage = fetchUsage
    }

    /// Fetches usage with the chosen source's token and no other. Self-contained mode never
    /// reads Claude Code's Keychain item: that read is what puts up the consent prompt, and
    /// avoiding it is the reason to choose self-contained sign-in. When our own sign-in is
    /// missing, or Anthropic rejects it (a 401 from usage, `invalid_grant` on refresh), the rejected
    /// pair is dropped (never a newer sign-in that landed meanwhile) and the error is
    /// `signedOut`, so the menu can say to sign in again. A network or server error is
    /// rethrown and the sign-in kept.
    public func fetch(preferSelfContained: Bool = false) async throws -> UsageResponse {
        guard preferSelfContained else {
            guard let token = await claudeCodeToken() else {
                throw UsageClient.UsageError.noToken
            }
            let response = try await fetchUsage(token)
            logger.notice("usage served via \(TokenSource.claudeCode.rawValue, privacy: .public) for account \(self.accountID, privacy: .public)")
            return response
        }

        let token = try await selfContainedTokenOrSignedOut()
        do {
            return try await serveSelfContained(token)
        } catch UsageClient.UsageError.unauthorized {
            if await clearSelfContained(token) {
                logger.notice("self-contained token rejected (401); sign in again to restore")
                throw UsageClient.UsageError.signedOut
            }
            // A newer sign-in replaced the rejected one while the request was in flight: try
            // that once rather than telling a freshly signed-in user to sign in again.
            logger.notice("self-contained token rejected (401), but a newer sign-in replaced it; retrying with that")
            let replacement = try await selfContainedTokenOrSignedOut()
            do {
                return try await serveSelfContained(replacement)
            } catch UsageClient.UsageError.unauthorized {
                if await clearSelfContained(replacement) {
                    logger.notice("replacement token rejected (401) too; sign in again to restore")
                    throw UsageClient.UsageError.signedOut
                }
                // Replaced yet again mid-request: fail this poll, and the next one uses it.
                throw UsageClient.UsageError.http(401)
            }
        }
    }

    /// Our token, or `signedOut` when there isn't a usable one.
    private func selfContainedTokenOrSignedOut() async throws -> String {
        do {
            guard let token = try await currentSelfContainedToken() else {
                logger.notice("usage skipped: no self-contained sign-in for account \(self.accountID, privacy: .public)")
                throw UsageClient.UsageError.signedOut
            }
            return token
        } catch SelfContainedCredentialStore.StoreError.grantRejected(let status) {
            // The store has already cleared the pair it refreshed.
            logger.notice("self-contained refresh rejected (\(status, privacy: .public)); sign in again to restore")
            throw UsageClient.UsageError.signedOut
        }
    }

    private func serveSelfContained(_ token: String) async throws -> UsageResponse {
        let response = try await fetchUsage(token)
        logger.notice("usage served via \(TokenSource.selfContained.rawValue, privacy: .public) for account \(self.accountID, privacy: .public)")
        return response
    }

    private let accountClient = AccountClient()
    /// Keyed by the token that resolved it: switching source or signing in to another
    /// account must never pair a new token with the old account's organization.
    private var organizationUUID: (token: String, uuid: String)?

    /// Guest passes and promotional credit for telemetry. Best effort by design: each part
    /// that fails is logged and left nil, and nothing here clears or swaps credentials — the
    /// usage fetch above owns that decision.
    public func fetchAccountOffers(preferSelfContained: Bool = false) async -> AccountOffers {
        guard let token = await accountToken(preferSelfContained: preferSelfContained) else {
            logger.notice("account offers skipped: no token")
            return AccountOffers()
        }

        let organization: String
        if let cached = organizationUUID, cached.token == token {
            organization = cached.uuid
        } else {
            do {
                organization = try await accountClient.organizationUUID(token: token)
                organizationUUID = (token, organization)
            } catch {
                logger.error("account offers skipped: organization lookup failed: \(String(describing: error), privacy: .public)")
                return AccountOffers()
            }
        }

        var offers = AccountOffers()
        do {
            offers.guestPasses = try await accountClient.guestPasses(organization: organization, token: token)
        } catch {
            logger.error("guest pass fetch failed: \(String(describing: error), privacy: .public)")
        }
        do {
            offers.creditGrant = try await accountClient.creditGrant(organization: organization, token: token)
        } catch {
            logger.error("credit grant fetch failed: \(String(describing: error), privacy: .public)")
        }
        return offers
    }

    /// Same source as `fetch()`, and the same rule: self-contained mode uses our token or
    /// nothing. Any failure skips the offers; clearing a rejected sign-in is left to `fetch()`.
    private func accountToken(preferSelfContained: Bool) async -> String? {
        guard preferSelfContained else {
            return await claudeCodeToken()
        }
        do {
            return try await currentSelfContainedToken()
        } catch {
            logger.notice("account offers skipped: self-contained token unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The stored sign-in after making sure it is fresh, for callers that need more than the
    /// access token (the identity lookup). The refresh goes through the same single-flight as
    /// usage and offers, so none of them can spend the refresh token twice. Nil when there is
    /// no usable sign-in; clearing a rejected one stays with `fetch`.
    public func selfContainedTokens() async -> OAuthTokens? {
        do {
            guard try await currentSelfContainedToken() != nil else { return nil }
        } catch {
            logger.notice("self-contained tokens unavailable for account \(self.accountID, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        return loadSelfContained()
    }

    private func currentSelfContainedToken() async throws -> String? {
        try await tokenFlight.run(selfContainedToken)
    }
}
