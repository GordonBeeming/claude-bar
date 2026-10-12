import CryptoKit
import Foundation
import Testing
@testable import ClaudeBarCore

struct PKCETests {
    @Test func verifierIsBase64URLWithoutPadding() {
        let pkce = PKCE()
        // 32 random bytes → 43 base64url chars, and none of the URL-unsafe / padding chars.
        #expect(pkce.verifier.count == 43)
        #expect(!pkce.verifier.contains("+"))
        #expect(!pkce.verifier.contains("/"))
        #expect(!pkce.verifier.contains("="))
    }

    @Test func challengeIsS256OfVerifier() {
        let pkce = PKCE()
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncodedString()
        #expect(pkce.challenge == expected)
    }

    @Test func pairsAreUnique() {
        #expect(PKCE().verifier != PKCE().verifier)
    }
}

struct OAuthURLTests {
    @Test func authorizeURLCarriesEveryRequiredParam() {
        let url = OAuthClient.authorizeURL(challenge: "CHAL", state: "STATE")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let params = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        #expect(url.host == "claude.com")
        #expect(params["client_id"] == OAuthConfig.clientID)
        #expect(params["response_type"] == "code")
        #expect(params["redirect_uri"] == OAuthConfig.redirectURI)
        // Pinned as a literal rather than compared to OAuthConfig.scopes: this is the
        // assertion that has to fail if someone widens the constant, and comparing the
        // constant to itself would let any change through.
        #expect(params["scope"] == "user:profile")
        #expect(params["code_challenge"] == "CHAL")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "STATE")
        #expect(params["code"] == "true")
    }
}

struct OAuthScopeTests {
    @Test func requestsOnlyWhatTheUsageEndpointNeeds() {
        // `user:profile` was verified live as sufficient for GET /api/oauth/usage. See the
        // note on OAuthConfig.scopes before changing this.
        #expect(OAuthConfig.scopes == "user:profile")
    }

    @Test func neverRequestsApiKeyCreation() {
        // The point of the whole change: this token must not be able to mint org API keys.
        #expect(!OAuthConfig.scopes.contains("org:create_api_key"))
    }
}

enum OAuthFixtures {
    /// Exactly the shape a build before scope-recording wrote to the Keychain: no `scope`
    /// key at all. Shared with `SelfContainedCredentialStoreTests`, which plants this blob
    /// into a real Keychain item — the encoder now always emits `scope`, so a literal is the
    /// only way to reproduce a pre-change item.
    static let legacyKeychainItem = #"{"accessToken":"at","refreshToken":"rt","expiresAt":760000000}"#
}

struct OAuthTokenDecodingTests {
    /// A synthesized decode would throw on the legacy item and sign the user out with no
    /// explanation, so this pins the legacy path.
    @Test func legacyItemWithoutScopeDecodesAsUnknown() throws {
        let tokens = try JSONDecoder().decode(
            OAuthTokens.self, from: Data(OAuthFixtures.legacyKeychainItem.utf8)
        )

        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.scope == OAuthTokens.unknownScope)
    }

    @Test func legacyItemIsTreatedAsStale() throws {
        let tokens = try JSONDecoder().decode(
            OAuthTokens.self, from: Data(OAuthFixtures.legacyKeychainItem.utf8)
        )

        #expect(OAuthTokens.isStale(storedScope: tokens.scope, requestedScope: OAuthConfig.scopes))
    }

    @Test func currentItemRoundTrips() throws {
        let original = OAuthTokens(
            accessToken: "at",
            refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 1_000_000),
            scope: "user:profile"
        )
        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
    }
}

/// Covers the wire contract the stored scope is built from: the server's `scope` wins when it
/// sends one, and its absence must not fail the exchange (the client substitutes a fallback).
struct OAuthTokenResponseTests {
    @Test func serverScopeIsDecoded() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"scope":"user:profile"}"#
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(json.utf8))

        #expect(decoded.scope == "user:profile")
        #expect(decoded.accessToken == "at")
        #expect(decoded.refreshToken == "rt")
        #expect(decoded.expiresIn == 3600)
    }

    @Test func responseWithoutScopeStillDecodes() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: Data(json.utf8))

        // nil, not "" — the client can only tell "server said nothing" from "server said
        // nothing was granted" if the missing case stays distinguishable.
        #expect(decoded.scope == nil)
    }
}

struct OAuthScopeStalenessTests {
    private let requested = "user:profile"

    @Test func unknownScopeIsStale() {
        #expect(OAuthTokens.isStale(storedScope: OAuthTokens.unknownScope, requestedScope: requested))
    }

    @Test func theOldWideGrantIsStale() {
        // The exact string shipped before this change.
        #expect(OAuthTokens.isStale(
            storedScope: "org:create_api_key user:profile user:inference",
            requestedScope: requested
        ))
    }

    @Test func anyExtraScopeIsStale() {
        #expect(OAuthTokens.isStale(storedScope: "user:profile user:inference", requestedScope: requested))
    }

    @Test func matchingScopeIsKept() {
        #expect(!OAuthTokens.isStale(storedScope: "user:profile", requestedScope: requested))
    }

    @Test func narrowerScopeIsKept() {
        // Re-signing in someone whose token is already tighter than we ask for would be
        // churn for no security gain.
        #expect(!OAuthTokens.isStale(storedScope: "user:profile", requestedScope: "user:profile user:inference"))
    }

    @Test func scopeOrderIsIrrelevant() {
        #expect(!OAuthTokens.isStale(
            storedScope: "user:inference user:profile",
            requestedScope: "user:profile user:inference"
        ))
    }
}

struct OAuthCallbackParseTests {
    @Test func bareCodeIsAccepted() throws {
        #expect(try OAuthClient.parseCallbackCode("abc123", expectedState: "s") == "abc123")
    }

    @Test func codeWithMatchingStateStripsTheState() throws {
        #expect(try OAuthClient.parseCallbackCode("abc123#s", expectedState: "s") == "abc123")
    }

    @Test func codeWithWrongStateThrows() {
        #expect(throws: OAuthClient.OAuthError.stateMismatch) {
            _ = try OAuthClient.parseCallbackCode("abc123#other", expectedState: "s")
        }
    }

    @Test func emptyPasteThrows() {
        #expect(throws: OAuthClient.OAuthError.self) {
            _ = try OAuthClient.parseCallbackCode("   ", expectedState: "s")
        }
    }
}

struct OAuthRefreshTimingTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func refreshesWhenInsideBuffer() {
        // Expires in 60s, buffer 120s → refresh now.
        #expect(OAuthClient.needsRefresh(expiresAt: now.addingTimeInterval(60), now: now))
    }

    @Test func doesNotRefreshWhenComfortablyValid() {
        // Expires in an hour → no refresh.
        #expect(!OAuthClient.needsRefresh(expiresAt: now.addingTimeInterval(3600), now: now))
    }
}
