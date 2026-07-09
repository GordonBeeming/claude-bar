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
                logger.notice("self-contained token rejected (401) — falling back to Claude Code token")
            } catch OAuthClient.OAuthError.http(let status) where status == 400 || status == 401 {
                logger.notice("self-contained refresh rejected (\(status, privacy: .public)) — falling back to Claude Code token")
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
}
