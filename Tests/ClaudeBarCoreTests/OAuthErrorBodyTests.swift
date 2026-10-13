import Foundation
import Testing
@testable import ClaudeBarCore

struct OAuthErrorBodyTests {
    @Test("A non-2xx body with an OAuth error code is a rejection carrying that code")
    func readsErrorCode() {
        let body = Data(#"{"error":"invalid_grant","error_description":"Refresh token expired"}"#.utf8)
        #expect(OAuthClient.error(status: 400, body: body) == .rejected(status: 400, code: "invalid_grant"))
    }

    @Test("A body without an OAuth error code stays a plain HTTP error")
    func plainHTTPOtherwise() {
        #expect(OAuthClient.error(status: 503, body: Data("<html>busy</html>".utf8)) == .http(503))
        #expect(OAuthClient.error(status: 400, body: Data(#"{"message":"bad"}"#.utf8)) == .http(400))
        #expect(OAuthClient.error(status: 400, body: Data(#"{"error":""}"#.utf8)) == .http(400))
    }
}
