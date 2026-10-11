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

    private let credentialsProvider = CredentialsProvider()
    private let selfContained = SelfContainedCredentialStore()
    private let client = UsageClient()
    private let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "UsageService")

    public init() {}

    /// Fetches usage. When `preferSelfContained` is set, our own token is tried first and
    /// the fetch falls back to Claude Code's token only on a genuine auth rejection — the
    /// usage API rejecting our token (401), or a refresh rejected as expired/revoked
    /// (400/401). A network or server error is rethrown instead, so an offline poll fails
    /// quietly rather than reaching for Claude Code's Keychain item (which would prompt and
    /// then fail anyway). A missing token (not signed in) just falls through.
    public func fetch(preferSelfContained: Bool = false) async throws -> UsageResponse {
        if preferSelfContained {
            do {
                if let token = try await selfContained.validAccessToken() {
                    let response = try await client.fetchUsage(token: token)
                    logger.notice("usage served via \(TokenSource.selfContained.rawValue, privacy: .public)")
                    return response
                }
            } catch UsageClient.UsageError.unauthorized {
                // Token is genuinely rejected — drop it so we don't re-send a known-bad token
                // every poll; the user re-signs in to restore self-contained mode.
                selfContained.clear()
                logger.notice("self-contained token rejected (401) — cleared it, falling back to Claude Code token")
            } catch OAuthClient.OAuthError.http(let status) where status == 400 || status == 401 {
                // Refresh token is expired/revoked — same deal, drop the dead pair.
                selfContained.clear()
                logger.notice("self-contained refresh rejected (\(status, privacy: .public)) — cleared it, falling back to Claude Code token")
            }
            // Any other error (network/server/timeout) propagates — no needless Keychain hit.
        }

        guard let token = credentialsProvider.loadAccessToken() else {
            throw UsageClient.UsageError.noToken
        }
        let response = try await client.fetchUsage(token: token)
        logger.notice("usage served via \(TokenSource.claudeCode.rawValue, privacy: .public)")
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

    /// Same selection as `fetch()`: Claude Code's token stands in only when ours is missing or
    /// genuinely rejected. On a network or server error the usage just shown may still be
    /// from our account, so falling back could pair it with another account's offers; skip.
    private func accountToken(preferSelfContained: Bool) async -> String? {
        if preferSelfContained {
            do {
                if let token = try await selfContained.validAccessToken() { return token }
            } catch OAuthClient.OAuthError.http(let status) where status == 400 || status == 401 {
                logger.notice("self-contained refresh rejected (\(status, privacy: .public)) for account offers, using Claude Code token")
            } catch {
                logger.notice("account offers skipped: self-contained token unavailable: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        return credentialsProvider.loadAccessToken()
    }
}
