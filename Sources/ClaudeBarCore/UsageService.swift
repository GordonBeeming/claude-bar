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

    /// Fetches usage. When `preferSelfContained` is set, our own token is tried first and,
    /// if it's missing or the API rejects it (401), the fetch falls back to Claude Code's
    /// token — so a lapsed self-contained sign-in degrades to the existing behaviour (worst
    /// case, the Keychain prompt) instead of breaking the app.
    public func fetch(preferSelfContained: Bool = false) async throws -> UsageResponse {
        if preferSelfContained, let token = await selfContained.validAccessToken() {
            do {
                let response = try await client.fetchUsage(token: token)
                logger.notice("usage served via \(TokenSource.selfContained.rawValue, privacy: .public)")
                return response
            } catch UsageClient.UsageError.unauthorized {
                // Our token was rejected — fall through to Claude Code's token below.
                logger.notice("self-contained token rejected (401) — falling back to Claude Code token")
            }
        }

        guard let token = credentialsProvider.loadAccessToken() else {
            throw UsageClient.UsageError.noToken
        }
        let response = try await client.fetchUsage(token: token)
        logger.notice("usage served via \(TokenSource.claudeCode.rawValue, privacy: .public)")
        return response
    }
}
