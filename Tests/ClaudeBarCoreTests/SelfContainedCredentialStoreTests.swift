import Foundation
import Security
import Testing
@testable import ClaudeBarCore

/// Captures the refresh tokens handed to the revoke handler, so a test can assert the grant
/// was retired with Anthropic without posting anything to Anthropic.
private actor RevokeRecorder {
    private(set) var revoked: [String] = []

    func record(_ refreshToken: String) { revoked.append(refreshToken) }
}

/// Gated on a usable Keychain: a CI runner may have no unlocked login keychain, and failing
/// there would say nothing about the code. `OAuthScopeStalenessTests` covers the staleness
/// decision unconditionally; these add what only a real item shows — that a stale grant is
/// deleted rather than ignored, and that neither a landing refresh nor a revoke can disturb a
/// credential the user has since signed back in with.
struct SelfContainedCredentialStoreTests {
    private static func store(
        _ service: String,
        recordingRevokesTo recorder: RevokeRecorder? = nil
    ) -> SelfContainedCredentialStore {
        SelfContainedCredentialStore(service: service, revokeHandler: { await recorder?.record($0) })
    }

    private static func tokens(scope: String) -> OAuthTokens {
        OAuthTokens(
            accessToken: "at",
            refreshToken: "rt",
            expiresAt: Date().addingTimeInterval(3600),
            scope: scope
        )
    }

    static let keychainAvailable: Bool = {
        let probe = store("com.gordonbeeming.ClaudeBar.tests.probe")
        defer { probe.clear() }
        return probe.save(tokens(scope: OAuthConfig.scopes))
    }()

    /// Writes bytes to the item directly, bypassing `save()`, so a pre-change blob can be
    /// planted — the encoder now always emits `scope`, so there's no other way to produce one.
    private static func writeRaw(_ json: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "oauth-tokens"
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query.merging([kSecValueData as String: Data(json.utf8)]) { _, new in new } as CFDictionary, nil)
    }

    /// Revocation is deliberately not asserted on the stale-scope path: `retireStaleGrant`
    /// fires it detached, so any assertion on it would be a race. The handler is stubbed to
    /// keep the test off the network, which is the property that matters here; the same
    /// handler is asserted directly on the (awaited) sign-out path below.
    @Test(.enabled(if: keychainAvailable))
    func widerStoredScopeIsClearedAndSignsTheUserOut() {
        let service = "com.gordonbeeming.ClaudeBar.tests.wide"
        let store = Self.store(service)
        defer { store.clear() }

        let wide = Self.tokens(scope: "org:create_api_key user:profile user:inference")
        #expect(store.save(wide))

        #expect(store.evaluate() == .clearedStaleScope(storedScope: wide.scope))
        // Gone, not just refused: a second look finds nothing at all.
        #expect(store.evaluate() == .missing)
        #expect(store.load() == nil)
        #expect(!store.isSignedIn)
    }

    @Test(.enabled(if: keychainAvailable))
    func legacyItemWithoutScopeIsClearedAndSignsTheUserOut() {
        let service = "com.gordonbeeming.ClaudeBar.tests.legacy"
        let store = Self.store(service)
        defer { store.clear() }

        Self.writeRaw(OAuthFixtures.legacyKeychainItem, service: service)

        #expect(store.evaluate() == .clearedStaleScope(storedScope: OAuthTokens.unknownScope))
        #expect(store.evaluate() == .missing)
        #expect(!store.isSignedIn)
    }

    @Test(.enabled(if: keychainAvailable))
    func currentScopeSurvives() {
        let service = "com.gordonbeeming.ClaudeBar.tests.current"
        let store = Self.store(service)
        defer { store.clear() }

        let tokens = Self.tokens(scope: OAuthConfig.scopes)
        #expect(store.save(tokens))

        #expect(store.evaluate() == .usable(tokens))
        #expect(store.isSignedIn)
    }

    /// The two halves sign-out composes: delete our copy, then revoke the token we captured.
    /// Deleting alone would leave the grant usable by anyone who already had the token.
    @Test(.enabled(if: keychainAvailable))
    func clearThenRevokeRemovesAndRetiresTheGrant() async {
        let service = "com.gordonbeeming.ClaudeBar.tests.signout"
        let recorder = RevokeRecorder()
        let store = Self.store(service, recordingRevokesTo: recorder)
        defer { store.clear() }

        let tokens = Self.tokens(scope: OAuthConfig.scopes)
        #expect(store.save(tokens))

        store.clear()
        await store.revokeGrant(refreshToken: tokens.refreshToken)

        // The *refresh* token: revoking it retires the access token issued alongside it too.
        #expect(await recorder.revoked == [tokens.refreshToken])
        #expect(store.evaluate() == .missing)
        #expect(!store.isSignedIn)
    }

    /// `revokeGrant` is handed a token instead of reading the Keychain, so a sign-in landing
    /// between the delete and the (detached, slow) revoke keeps its credential — and it's the
    /// old grant that gets retired, not the new one.
    @Test(.enabled(if: keychainAvailable))
    func revokingDoesNotDisturbACredentialSavedAfterTheDelete() async {
        let service = "com.gordonbeeming.ClaudeBar.tests.signout-then-signin"
        let recorder = RevokeRecorder()
        let store = Self.store(service, recordingRevokesTo: recorder)
        defer { store.clear() }

        let old = Self.tokens(scope: OAuthConfig.scopes)
        #expect(store.save(old))
        store.clear()

        // A fresh sign-in completes here, before the revoke runs.
        let fresh = OAuthTokens(
            accessToken: "fresh-at",
            refreshToken: "fresh-rt",
            expiresAt: Date().addingTimeInterval(3600),
            scope: OAuthConfig.scopes
        )
        #expect(store.save(fresh))

        await store.revokeGrant(refreshToken: old.refreshToken)

        #expect(await recorder.revoked == [old.refreshToken])
        #expect(store.load()?.accessToken == "fresh-at")
        #expect(store.isSignedIn)
    }

    private static func rotated(from previous: OAuthTokens) -> OAuthTokens {
        OAuthTokens(
            accessToken: "rotated-at",
            refreshToken: "rotated-rt",
            expiresAt: previous.expiresAt.addingTimeInterval(3600),
            scope: previous.scope
        )
    }

    @Test(.enabled(if: keychainAvailable))
    func rotatedPairReplacesTheCredentialItCameFrom() {
        let service = "com.gordonbeeming.ClaudeBar.tests.rotate"
        let store = Self.store(service)
        defer { store.clear() }

        let original = Self.tokens(scope: OAuthConfig.scopes)
        #expect(store.save(original))

        #expect(store.saveRotated(Self.rotated(from: original), replacing: original) == .saved)
        #expect(store.load()?.accessToken == "rotated-at")
    }

    /// A refresh that lands after sign-out must not resurrect the credential. A plain `save`
    /// would: its `SecItemAdd` fallback re-creates a deleted item, leaving a usable token
    /// behind a signed-out UI.
    @Test(.enabled(if: keychainAvailable))
    func refreshLandingAfterSignOutDoesNotResurrectTheCredential() {
        let service = "com.gordonbeeming.ClaudeBar.tests.rotate-after-signout"
        let store = Self.store(service)
        defer { store.clear() }

        let original = Self.tokens(scope: OAuthConfig.scopes)
        #expect(store.save(original))
        store.clear()

        #expect(store.saveRotated(Self.rotated(from: original), replacing: original) == .superseded)
        #expect(store.evaluate() == .missing)
        #expect(!store.isSignedIn)
    }

    /// The harder version: the user signs out *and back in* while a refresh is in flight. The
    /// item exists again, so an update matching only service+account would overwrite the fresh
    /// credential with the old grant's rotated tokens. Matching on the credential being
    /// replaced makes it a no-op instead.
    @Test(.enabled(if: keychainAvailable))
    func refreshLandingAfterAFreshSignInDoesNotOverwriteIt() {
        let service = "com.gordonbeeming.ClaudeBar.tests.rotate-after-resignin"
        let store = Self.store(service)
        defer { store.clear() }

        let original = Self.tokens(scope: OAuthConfig.scopes)
        #expect(store.save(original))
        store.clear()

        let fresh = OAuthTokens(
            accessToken: "fresh-at",
            refreshToken: "fresh-rt",
            expiresAt: Date().addingTimeInterval(3600),
            scope: OAuthConfig.scopes
        )
        #expect(store.save(fresh))

        #expect(store.saveRotated(Self.rotated(from: original), replacing: original) == .superseded)
        #expect(store.load()?.accessToken == "fresh-at")
        #expect(store.isSignedIn)
    }

    /// `evaluate()` maps an undecodable item to `.missing` and leaves the bytes alone; pinned
    /// so the leave-in-place choice is deliberate rather than incidental.
    @Test(.enabled(if: keychainAvailable))
    func undecodableItemReadsAsMissing() {
        let service = "com.gordonbeeming.ClaudeBar.tests.corrupt"
        let store = Self.store(service)
        defer { store.clear() }

        Self.writeRaw("not json at all", service: service)

        #expect(store.evaluate() == .missing)
        #expect(store.load() == nil)
        #expect(!store.isSignedIn)
    }

}
