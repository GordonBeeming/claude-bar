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

    private let selfContainedToken: @Sendable () async throws -> String?
    private let claudeCodeToken: @Sendable () async -> String?
    private let clearSelfContained: @Sendable () async -> Void
    private let fetchUsage: @Sendable (String) async throws -> UsageResponse
    /// Shared by the usage poll and the account-offers fetch, which can ask at the same
    /// moment: each refresh spends our single-use refresh token, so they must not both refresh.
    private let tokenFlight = SingleFlight<String?>()
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "UsageService")

    public init() {
        let store = SelfContainedCredentialStore()
        let credentials = CredentialsProvider()
        let client = UsageClient()
        self.init(
            selfContainedToken: { try await store.validAccessToken() },
            claudeCodeToken: { credentials.loadAccessToken() },
            clearSelfContained: { store.clear() },
            fetchUsage: { try await client.fetchUsage(token: $0) }
        )
    }

    init(
        selfContainedToken: @escaping @Sendable () async throws -> String?,
        claudeCodeToken: @escaping @Sendable () async -> String?,
        clearSelfContained: @escaping @Sendable () async -> Void,
        fetchUsage: @escaping @Sendable (String) async throws -> UsageResponse
    ) {
        self.selfContainedToken = selfContainedToken
        self.claudeCodeToken = claudeCodeToken
        self.clearSelfContained = clearSelfContained
        self.fetchUsage = fetchUsage
    }

    /// Fetches usage with the chosen source's token and no other. Self-contained mode never
    /// reads Claude Code's Keychain item: that read is what puts up the consent prompt, and
    /// avoiding it is the reason to choose self-contained sign-in. When our own sign-in is
    /// missing, or Anthropic rejects it (a 401 from usage, a 400/401 refresh), the dead pair
    /// is dropped and the error is `signedOut`, so the menu can say to sign in again. A
    /// network or server error is rethrown and the sign-in kept.
    public func fetch(preferSelfContained: Bool = false) async throws -> UsageResponse {
        guard preferSelfContained else {
            guard let token = await claudeCodeToken() else {
                throw UsageClient.UsageError.noToken
            }
            let response = try await fetchUsage(token)
            logger.notice("usage served via \(TokenSource.claudeCode.rawValue, privacy: .public)")
            return response
        }

        do {
            guard let token = try await currentSelfContainedToken() else {
                logger.notice("usage skipped: no self-contained sign-in")
                throw UsageClient.UsageError.signedOut
            }
            let response = try await fetchUsage(token)
            logger.notice("usage served via \(TokenSource.selfContained.rawValue, privacy: .public)")
            return response
        } catch UsageClient.UsageError.unauthorized {
            await clearSelfContained()
            logger.notice("self-contained token rejected (401), cleared it; sign in again to restore")
            throw UsageClient.UsageError.signedOut
        } catch OAuthClient.OAuthError.http(let status) where status == 400 || status == 401 {
            await clearSelfContained()
            logger.notice("self-contained refresh rejected (\(status, privacy: .public)), cleared it; sign in again to restore")
            throw UsageClient.UsageError.signedOut
        }
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

    private func currentSelfContainedToken() async throws -> String? {
        try await tokenFlight.run(selfContainedToken)
    }
}
