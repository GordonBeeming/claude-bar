import Testing
@testable import ClaudeBarCore

struct HighestLimitSelectionTests {
    @Test func picksHighestPercent() {
        let session = UsageLimit(kind: "session", percent: 11, severity: .normal)
        let weeklyAll = UsageLimit(kind: "weekly_all", percent: 89, severity: .warning)
        let weeklyScoped = UsageLimit(kind: "weekly_scoped", percent: 0, severity: .normal)

        let result = highestLimit(in: [session, weeklyAll, weeklyScoped])
        #expect(result?.kind == "weekly_all")
    }

    @Test func tieOnPercentPicksHigherSeverity() {
        let normal = UsageLimit(kind: "session", percent: 50, severity: .normal)
        let critical = UsageLimit(kind: "weekly_all", percent: 50, severity: .critical)

        let result = highestLimit(in: [normal, critical])
        #expect(result?.kind == "weekly_all")
        #expect(result?.severity == .critical)
    }

    @Test func emptyListReturnsNil() {
        #expect(highestLimit(in: []) == nil)
    }
}
