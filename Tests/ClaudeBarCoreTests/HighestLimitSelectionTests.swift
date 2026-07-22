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

    @Test func menuBarDefaultsToHighestLimit() {
        let session = UsageLimit(kind: "session", percent: 11, severity: .normal)
        let weekly = UsageLimit(kind: "weekly_all", percent: 89, severity: .warning)

        #expect(menuBarLimit(in: [session, weekly], selectedKey: nil)?.kind == "weekly_all")
    }

    @Test func menuBarUsesSelectedLimit() {
        let session = UsageLimit(kind: "session", percent: 11, severity: .normal)
        let weekly = UsageLimit(kind: "weekly_all", percent: 89, severity: .warning)

        #expect(menuBarLimit(in: [session, weekly], selectedKey: session.selectionKey)?.kind == "session")
    }

    @Test func menuBarFallsBackToHighestWhenSelectionIsMissing() {
        let session = UsageLimit(kind: "session", percent: 11, severity: .normal)
        let weekly = UsageLimit(kind: "weekly_all", percent: 89, severity: .warning)

        #expect(menuBarLimit(in: [session, weekly], selectedKey: "monthly_all")?.kind == "weekly_all")
    }

    @Test func menuBarUsesSelectionKeyForScopedLimitsWithDuplicateIDs() {
        let sonnet = UsageLimit(
            kind: "weekly_scoped",
            percent: 10,
            severity: .normal,
            scope: LimitScope(model: .init(id: "sonnet"))
        )
        let opus = UsageLimit(
            kind: "weekly_scoped",
            percent: 90,
            severity: .warning,
            scope: LimitScope(model: .init(id: "opus"))
        )

        #expect(sonnet.id == opus.id)
        #expect(sonnet.selectionKey != opus.selectionKey)
        #expect(menuBarLimit(in: [sonnet, opus], selectedKey: sonnet.selectionKey)?.percent == 10)
    }

    @Test func menuBarSelectionKeySurvivesScopedModelDisplayNameChanges() {
        let selected = UsageLimit(
            kind: "weekly_scoped",
            percent: 10,
            severity: .normal,
            scope: LimitScope(model: .init(id: "sonnet", displayName: "Sonnet"))
        )
        let refreshed = UsageLimit(
            kind: "weekly_scoped",
            percent: 25,
            severity: .normal,
            scope: LimitScope(model: .init(id: "sonnet", displayName: "Sonnet 4"))
        )

        #expect(selected.selectionKey == refreshed.selectionKey)
        #expect(menuBarLimit(in: [refreshed], selectedKey: selected.selectionKey)?.percent == 25)
    }
}
