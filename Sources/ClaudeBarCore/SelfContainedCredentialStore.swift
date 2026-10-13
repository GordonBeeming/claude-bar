import CryptoKit
import Foundation
import os
import Security

/// Reads and writes *our own* OAuth token pair in a Keychain item this app created. Because
/// we own the item, macOS never shows the cross-app consent prompt that reading Claude
/// Code's item triggers — that's the whole point of self-contained sign-in. Refreshes are
/// our token's, so they never disturb Claude Code's credentials.
public struct SelfContainedCredentialStore: Sendable {
    public enum StoreError: Error, Equatable {
        case keychainWriteFailed
        /// Anthropic refused the refresh as expired or revoked (400/401). The pair that was
        /// refreshed has already been cleared, if it was still the stored one.
        case grantRejected(status: Int)
    }

    /// What was found in the Keychain. `clearedStaleScope` is reported rather than folded
    /// into `none` so Settings can explain the sign-out instead of the user finding
    /// themselves silently logged out.
    public enum StoredCredential: Sendable, Equatable {
        /// Named `missing` rather than `none` so a `case .none:` never reads as if `evaluate()`
        /// returned an Optional.
        case missing
        case usable(OAuthTokens)
        /// Dropped because its grant is wider than what this build requests, or predates
        /// scope recording. Carries the stored scope for logging (empty when unknown).
        case clearedStaleScope(storedScope: String)
    }

    private let service: String
    private let account = "oauth-tokens"
    private let client: OAuthClient
    /// How a retired grant gets revoked. Indirected purely so tests can exercise the
    /// stale-scope migration without posting a revoke to Anthropic; production always gets
    /// the real call below.
    private let revokeHandler: @Sendable (String) async -> Void

    private static let logger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "OAuthRevoke")
    /// Every way the stored sign-in can come back empty is logged here, so a drop-out names
    /// its cause instead of surfacing only as "signed out".
    private static let storeLogger = Logger(subsystem: "com.gordonbeeming.ClaudeBar", category: "SelfContainedCredentialStore")

    public init(service: String = "com.gordonbeeming.ClaudeBar.oauth", client: OAuthClient = OAuthClient()) {
        self.service = service
        self.client = client
        // Logged rather than swallowed: a failed revoke leaves the grant live until its refresh
        // token expires, and this is the only record that it happened. Still not rethrown —
        // callers have already deleted our copy and can't act on it.
        self.revokeHandler = { refreshToken in
            do {
                try await client.revoke(refreshToken: refreshToken)
            } catch {
                Self.logger.error("grant revocation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    init(service: String, client: OAuthClient = OAuthClient(), revokeHandler: @escaping @Sendable (String) async -> Void) {
        self.service = service
        self.client = client
        self.revokeHandler = revokeHandler
    }

    public var isSignedIn: Bool { load() != nil }

    /// The single chokepoint for reading the item, so the scope invariant can't be bypassed
    /// by a caller that reaches for the token directly.
    public func evaluate() -> StoredCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                Self.storeLogger.debug("no stored sign-in")
            } else {
                Self.storeLogger.error("reading the stored sign-in failed: OSStatus \(status, privacy: .public)")
            }
            return .missing
        }
        guard let data = item as? Data else {
            Self.storeLogger.error("stored sign-in returned no data")
            return .missing
        }
        // Undecodable bytes are left in place rather than deleted: there's no token to revoke,
        // the next sign-in overwrites the item anyway, and deleting on a failed decode would
        // add a destructive path for no gain.
        let tokens: OAuthTokens
        do {
            tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        } catch {
            Self.storeLogger.error("stored sign-in couldn't be decoded: \(String(describing: error), privacy: .public)")
            return .missing
        }
        guard OAuthTokens.isStale(storedScope: tokens.scope, requestedScope: OAuthConfig.scopes) else {
            return .usable(tokens)
        }
        Self.storeLogger.notice("retiring a stored grant with scope '\(tokens.scope, privacy: .public)', wider than '\(OAuthConfig.scopes, privacy: .public)'")
        retireStaleGrant(tokens)
        return .clearedStaleScope(storedScope: tokens.scope)
    }

    public func load() -> OAuthTokens? {
        guard case .usable(let tokens) = evaluate() else { return nil }
        return tokens
    }

    /// Retires a grant this build wouldn't ask for — in practice the old `org:create_api_key`
    /// pair. Deletes locally *and* revokes, since deleting alone leaves the grant usable by
    /// anyone who already captured it. The revoke is detached and best-effort: `evaluate()` is
    /// synchronous and on the poll path, and an offline revoke must not keep the over-scoped
    /// token in the Keychain. Deletion is the guaranteed step.
    private func retireStaleGrant(_ tokens: OAuthTokens) {
        clear()
        let revoke = revokeHandler
        let refreshToken = tokens.refreshToken
        Task.detached { await revoke(refreshToken) }
    }

    /// Persists the pair, replacing any existing one. Returns false if the Keychain write
    /// failed so the caller can surface it rather than silently believing sign-in worked.
    ///
    /// Updates in place rather than delete-then-add: a refresh rotates the single-use refresh
    /// token, so if a plain `SecItemAdd` failed after the old item was already deleted we'd
    /// have thrown away the only durable token. `SecItemUpdate` leaves the existing item
    /// intact when it fails, and we only `SecItemAdd` when there's nothing to update.
    @discardableResult
    public func save(_ tokens: OAuthTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // AfterFirstUnlock (not WhenUnlocked): the menu bar app polls on a timer that keeps
        // running while the screen is locked, so it must be able to read the token then.
        // ThisDeviceOnly keeps the credential from syncing to iCloud Keychain or a backup.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrGeneric as String: Self.identity(of: tokens),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    /// Tags a stored credential so a rotation can tell *which* one it's replacing. Hashed
    /// rather than stored raw: `kSecAttrGeneric` is a searchable attribute, and a refresh token
    /// has no business sitting in one.
    private static func identity(of tokens: OAuthTokens) -> Data {
        Data(SHA256.hash(data: Data(tokens.refreshToken.utf8)))
    }

    /// What happened when persisting a rotated pair. `superseded` is a legitimate outcome, not
    /// a failure: the credential we rotated from was signed out or replaced meanwhile.
    public enum RotatedSaveResult: Sendable, Equatable { case saved, superseded, failed }

    /// Persists a refreshed pair over the exact credential it was rotated from — a
    /// compare-and-swap, not a blind write, and never a create.
    ///
    /// A refresh is a network round trip, so the Keychain can change under it: the user can
    /// sign out, or sign out *and* sign back in, before it lands. Matching on the identity of
    /// `previous` means the Keychain itself arbitrates. If the item was deleted, or replaced by
    /// a different sign-in, nothing matches and the write is a no-op — where a blind
    /// service+account update would have clobbered a fresh credential with a stale grant's
    /// tokens, and a `SecItemAdd` fallback would have resurrected a signed-out one.
    func saveRotated(_ tokens: OAuthTokens, replacing previous: OAuthTokens) -> RotatedSaveResult {
        guard let data = try? JSONEncoder().encode(tokens) else { return .failed }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrGeneric as String: Self.identity(of: previous)
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrGeneric as String: Self.identity(of: tokens),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        switch SecItemUpdate(query as CFDictionary, attributes as CFDictionary) {
        case errSecSuccess: return .saved
        case errSecItemNotFound: return .superseded
        default: return .failed
        }
    }

    /// Deletes our copy of the token. This does *not* revoke the grant server-side — pair it
    /// with `revokeGrant(refreshToken:)`, as `OAuthLoginController.signOut()` does.
    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Deletes the stored pair only if it is still `tokens`, matched on the same identity
    /// `saveRotated` uses, so the Keychain arbitrates. A rejection that lands after the user
    /// signed in again must not delete the new sign-in. Returns whether anything was deleted.
    @discardableResult
    public func clear(ifStillHolding tokens: OAuthTokens) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrGeneric as String: Self.identity(of: tokens)
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Deletes the stored pair only if its access token is the one that was rejected. The
    /// usage request is a network round trip, so a new sign-in can replace the pair while it
    /// is in flight; that sign-in survives.
    @discardableResult
    public func clear(ifAccessToken accessToken: String) -> Bool {
        guard let stored = load(), stored.accessToken == accessToken else {
            Self.storeLogger.notice("rejected token is no longer the stored one; keeping the stored sign-in")
            return false
        }
        return clear(ifStillHolding: stored)
    }

    /// Revokes one specific grant. Deliberately takes the token rather than reading the
    /// Keychain itself: sign-out deletes synchronously and revokes detached, so a re-read here
    /// could pick up — and kill — a credential from a sign-in that completed in between. If the
    /// revoke fails the grant lives until its refresh token expires, which beats keeping our
    /// copy because the network was down.
    public func revokeGrant(refreshToken: String) async {
        await revokeHandler(refreshToken)
    }

    /// The current access token, refreshing first when it's near expiry. Returns nil when
    /// there's no stored token (not signed in). A refresh rejected as expired or revoked
    /// clears the pair that was refreshed (only if it's still the stored one) and throws
    /// `StoreError.grantRejected`. Any other refresh failure is rethrown with the sign-in kept,
    /// so a network or server error fails only this poll.
    public func validAccessToken(now: Date = Date()) async throws -> String? {
        guard let tokens = load() else { return nil }
        guard OAuthClient.needsRefresh(expiresAt: tokens.expiresAt, now: now) else {
            return tokens.accessToken
        }
        let refreshed: OAuthTokens
        do {
            refreshed = try await client.refresh(refreshToken: tokens.refreshToken, grantedScope: tokens.scope)
        } catch OAuthClient.OAuthError.http(let status) where status == 400 || status == 401 {
            let cleared = clear(ifStillHolding: tokens)
            Self.storeLogger.notice("refresh rejected (\(status, privacy: .public)); \(cleared ? "cleared that sign-in" : "a newer sign-in replaced it, kept that", privacy: .public)")
            throw StoreError.grantRejected(status: status)
        } catch {
            Self.storeLogger.error("token refresh failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        switch saveRotated(refreshed, replacing: tokens) {
        case .saved:
            Self.storeLogger.notice("token refreshed, granted scope '\(refreshed.scope, privacy: .public)'")
            return refreshed.accessToken
        case .superseded:
            // Signed out, or signed out and back in, while this refresh was in flight. Never
            // write the orphaned pair over whatever replaced it; use what's stored now instead,
            // which is a fresh sign-in's token or nothing.
            Self.storeLogger.notice("refreshed pair superseded by a sign-out or new sign-in; using what's stored now")
            return load()?.accessToken
        case .failed:
            // A refresh rotates the refresh token, so a failed write would strand us: the old
            // token is now invalid and the new one isn't persisted. Fail loudly instead.
            Self.storeLogger.error("saving the refreshed pair failed")
            throw StoreError.keychainWriteFailed
        }
    }
}
