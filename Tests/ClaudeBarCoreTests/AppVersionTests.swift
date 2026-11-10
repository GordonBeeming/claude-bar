import Testing
@testable import ClaudeBarCore

struct AppVersionTests {
    @Test func displayPrefersTheStampedString() {
        let info: [String: Any] = [
            "GBDisplayVersion": "0.13-dev (abc1234)",
            "CFBundleShortVersionString": "0.13",
            "CFBundleVersion": "0.13.1",
        ]
        #expect(AppVersion.display(from: info) == "0.13-dev (abc1234)")
    }

    @Test func displayFallsBackToShortAndBuild() {
        #expect(AppVersion.display(from: ["CFBundleShortVersionString": "0.13", "CFBundleVersion": "172"]) == "0.13 (172)")
        #expect(AppVersion.display(from: ["CFBundleShortVersionString": "0.13"]) == "0.13")
        #expect(AppVersion.display(from: ["GBDisplayVersion": "", "CFBundleShortVersionString": "0.13"]) == "0.13")
    }

    @Test func displayIsDevWithNothingToGoOn() {
        #expect(AppVersion.display(from: [:]) == "dev")
        #expect(AppVersion.display(from: ["CFBundleShortVersionString": 13]) == "dev")
    }

    @Test func shortIsMarkedForDevBuilds() {
        #expect(AppVersion.short(from: ["CFBundleShortVersionString": "0.13", "GBDisplayVersion": "0.13 (172)"]) == "v0.13")
        #expect(AppVersion.short(from: ["CFBundleShortVersionString": "0.13", "GBDisplayVersion": "0.13-dev (abc1234)"]) == "v0.13-dev")
        #expect(AppVersion.short(from: ["CFBundleShortVersionString": "0.13"]) == "v0.13")
        #expect(AppVersion.short(from: [:]) == "dev")
    }
}
