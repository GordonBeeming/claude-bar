import Testing
@testable import ClaudeBarCore

struct LimitPresentationTests {
    @Test func sessionDisplayName() {
        let limit = UsageLimit(kind: "session", percent: 11, severity: .normal)
        #expect(LimitPresentation.displayName(for: limit) == "Session (5h)")
    }

    @Test func weeklyAllDisplayName() {
        let limit = UsageLimit(kind: "weekly_all", percent: 89, severity: .warning)
        #expect(LimitPresentation.displayName(for: limit) == "Weekly (all models)")
    }

    @Test func weeklyScopedDisplayNameUsesModelName() {
        let scope = LimitScope(model: .init(displayName: "Fable"))
        let limit = UsageLimit(kind: "weekly_scoped", percent: 0, severity: .normal, scope: scope)
        #expect(LimitPresentation.displayName(for: limit) == "Weekly — Fable")
    }

    @Test func weeklyScopedFallsBackWithoutModelName() {
        let limit = UsageLimit(kind: "weekly_scoped", percent: 0, severity: .normal)
        #expect(LimitPresentation.displayName(for: limit) == "Weekly (scoped)")
    }

    @Test func unknownKindIsHumanized() {
        let limit = UsageLimit(kind: "monthly_all", percent: 5, severity: .normal)
        #expect(LimitPresentation.displayName(for: limit) == "Monthly all")
    }

    @Test func unknownScopedKindAppendsModelName() {
        let scope = LimitScope(model: .init(displayName: "Opus"))
        let limit = UsageLimit(kind: "monthly_scoped", percent: 5, severity: .normal, scope: scope)
        #expect(LimitPresentation.displayName(for: limit) == "Monthly scoped — Opus")
    }

    @Test func sortOrderPutsSessionFirstThenWeeklyByPercent() {
        let session = UsageLimit(kind: "session", group: "session", percent: 11, severity: .normal)
        let weeklyHigh = UsageLimit(kind: "weekly_all", group: "weekly", percent: 89, severity: .warning)
        let weeklyLow = UsageLimit(kind: "weekly_scoped", group: "weekly", percent: 0, severity: .normal)
        let other = UsageLimit(kind: "monthly_all", group: "monthly", percent: 50, severity: .normal)

        let sorted = LimitPresentation.sorted([other, weeklyLow, weeklyHigh, session])

        #expect(sorted.map(\.kind) == ["session", "weekly_all", "weekly_scoped", "monthly_all"])
    }
}
