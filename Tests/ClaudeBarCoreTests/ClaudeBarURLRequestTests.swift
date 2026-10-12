import Foundation
import Testing
@testable import ClaudeBarCore

struct ClaudeBarURLRequestTests {
    private func parse(_ string: String) throws -> ClaudeBarURLRequest {
        try ClaudeBarURLRequest.parse(try #require(URL(string: string)))
    }

    private func parseError(_ string: String) throws -> ClaudeBarURLRequest.ParseError? {
        let url = try #require(URL(string: string))
        do {
            _ = try ClaudeBarURLRequest.parse(url)
            return nil
        } catch {
            return error
        }
    }

    @Test func settingsOpensTheWindow() throws {
        #expect(try parse("claudebar://settings") == .openSettings)
        #expect(try parse("claudebar://settings/") == .openSettings)
    }

    @Test func allParametersParse() throws {
        let request = try parse("claudebar://telemetry?enabled=1&interval=15&retention=0&folder=%2FUsers%2Fme%2FMy%20Telemetry")
        #expect(request == .telemetry(.init(
            enabled: true,
            intervalMinutes: 15,
            retentionDays: 0,
            folder: URL(filePath: "/Users/me/My Telemetry", directoryHint: .isDirectory)
        )))
    }

    @Test func anySubsetIsAllowedAndUnknownParametersAreIgnored() throws {
        #expect(try parse("claudebar://telemetry?enabled=false&colour=blue") == .telemetry(.init(enabled: false)))
        #expect(try parse("claudebar://telemetry?interval=1440") == .telemetry(.init(intervalMinutes: 1440)))
        #expect(try parse("claudebar://telemetry?retention=3650") == .telemetry(.init(retentionDays: 3650)))
        guard case .telemetry(let empty) = try parse("claudebar://telemetry") else {
            Issue.record("expected a telemetry request")
            return
        }
        #expect(empty.isEmpty)
    }

    @Test func tildeFolderExpandsToHome() throws {
        guard case .telemetry(let change) = try parse("claudebar://telemetry?folder=~%2FTelemetry") else {
            Issue.record("expected a telemetry request")
            return
        }
        #expect(change.folder?.path == FileManager.default.homeDirectoryForCurrentUser.appending(path: "Telemetry").path)
    }

    @Test(arguments: [
        ("claudebar://telemetry?enabled=yes", "enabled"),
        ("claudebar://telemetry?interval=0", "interval"),
        ("claudebar://telemetry?interval=1441", "interval"),
        ("claudebar://telemetry?interval=5.5", "interval"),
        ("claudebar://telemetry?retention=-1", "retention"),
        ("claudebar://telemetry?retention=3651", "retention"),
        ("claudebar://telemetry?folder=relative%2Fpath", "folder"),
        ("claudebar://telemetry?folder=", "folder"),
        // A line break could pose as another line in the confirmation.
        ("claudebar://telemetry?folder=%2Ftmp%2Fhistory%0ATracking:%20Off%20%E2%86%92%20On", "folder"),
        ("claudebar://telemetry?folder=%2Ftmp%2Fa%09b", "folder"),
    ])
    func invalidValueRejectsTheWholeRequest(url: String, parameter: String) throws {
        // A valid parameter alongside doesn't rescue the request.
        let error = try parseError(url + "&enabled=1")
        guard case .invalidValue(let rejected, _, _) = error else {
            Issue.record("expected invalidValue for \(url), got \(String(describing: error))")
            return
        }
        #expect(rejected == parameter)
        #expect(error?.errorDescription?.isEmpty == false)
    }

    @Test func displayPathKeepsControlCharactersOnOneLine() {
        let url = URL(filePath: "/tmp/history\nTracking: Off → On")
        let shown = ClaudeBarURLRequest.displayPath(url)
        #expect(!shown.contains("\n"))
        #expect(shown == "/tmp/history\\u{000A}Tracking: Off → On")
        #expect(ClaudeBarURLRequest.displayPath(URL(filePath: "/tmp/plain")) == "/tmp/plain")
    }

    @Test func unknownActionAndSchemeAreRejected() throws {
        #expect(try parseError("claudebar://launch") == .unknownAction("launch"))
        #expect(try parseError("codexbar://settings") == .wrongScheme("codexbar"))
    }
}
