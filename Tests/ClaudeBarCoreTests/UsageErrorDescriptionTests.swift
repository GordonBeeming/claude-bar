import Foundation
import Testing
@testable import ClaudeBarCore

struct UsageErrorDescriptionTests {
    @Test("A usage error names the HTTP status, so the menu says what went wrong")
    func describesStatus() {
        #expect(UsageClient.UsageError.http(403).localizedDescription == "Anthropic answered HTTP 403")
        #expect(UsageClient.UsageError.http(-1).localizedDescription == "No HTTP response from Anthropic")
    }
}
