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
        #expect(params["scope"] == OAuthConfig.scopes)
        #expect(params["code_challenge"] == "CHAL")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "STATE")
        #expect(params["code"] == "true")
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
