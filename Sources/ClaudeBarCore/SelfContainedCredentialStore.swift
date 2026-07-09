import Foundation
import Security

/// Reads and writes *our own* OAuth token pair in a Keychain item this app created. Because
/// we own the item, macOS never shows the cross-app consent prompt that reading Claude
/// Code's item triggers — that's the whole point of self-contained sign-in. Refreshes are
/// our token's, so they never disturb Claude Code's credentials.
public struct SelfContainedCredentialStore: Sendable {
    private let service: String
    private let account = "oauth-tokens"
    private let client: OAuthClient

    public init(service: String = "com.gordonbeeming.ClaudeBar.oauth", client: OAuthClient = OAuthClient()) {
        self.service = service
        self.client = client
    }

    public var isSignedIn: Bool { load() != nil }

    public func load() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    /// Persists the pair, replacing any existing one. Returns false if the Keychain write
    /// failed so the caller can surface it rather than silently believing sign-in worked.
    @discardableResult
    public func save(_ tokens: OAuthTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// The current access token, refreshing first when it's near expiry. Returns nil on any
    /// failure (no stored token, refresh rejected) so the caller falls back to Claude Code's
    /// token rather than erroring the whole poll.
    public func validAccessToken(now: Date = Date()) async -> String? {
        guard let tokens = load() else { return nil }
        guard OAuthClient.needsRefresh(expiresAt: tokens.expiresAt, now: now) else {
            return tokens.accessToken
        }
        guard let refreshed = try? await client.refresh(refreshToken: tokens.refreshToken) else {
            return nil
        }
        save(refreshed)
        return refreshed.accessToken
    }
}
