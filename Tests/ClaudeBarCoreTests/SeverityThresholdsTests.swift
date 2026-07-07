import Testing
@testable import ClaudeBarCore

struct SeverityThresholdsTests {
    @Test func defaultUsesClaudeSeverityPassthrough() {
        let thresholds = SeverityThresholds()
        let limit = UsageLimit(kind: "session", percent: 10, severity: .critical)
        #expect(thresholds.resolve(for: limit) == .critical)
    }

    @Test func customModeBelowWarningIsNormal() {
        let thresholds = SeverityThresholds(useClaudeSeverity: false, warningPercent: 75, criticalPercent: 90)
        let limit = UsageLimit(kind: "session", percent: 74.9, severity: .normal)
        #expect(thresholds.resolve(for: limit) == .normal)
    }

    @Test func customModeAtWarningBoundaryIsWarning() {
        let thresholds = SeverityThresholds(useClaudeSeverity: false, warningPercent: 75, criticalPercent: 90)
        let limit = UsageLimit(kind: "session", percent: 75, severity: .normal)
        #expect(thresholds.resolve(for: limit) == .warning)
    }

    @Test func customModeJustBelowCriticalIsWarning() {
        let thresholds = SeverityThresholds(useClaudeSeverity: false, warningPercent: 75, criticalPercent: 90)
        let limit = UsageLimit(kind: "session", percent: 89.9, severity: .normal)
        #expect(thresholds.resolve(for: limit) == .warning)
    }

    @Test func customModeAtCriticalBoundaryIsCritical() {
        let thresholds = SeverityThresholds(useClaudeSeverity: false, warningPercent: 75, criticalPercent: 90)
        let limit = UsageLimit(kind: "session", percent: 90, severity: .normal)
        #expect(thresholds.resolve(for: limit) == .critical)
    }

    @Test func percentagesClampToOneHundred() {
        var thresholds = SeverityThresholds(useClaudeSeverity: false)
        thresholds.warningPercent = 500
        thresholds.criticalPercent = -10
        #expect(thresholds.warningPercent == 100)
        #expect(thresholds.criticalPercent == 1)
    }

    @Test func invertedWarningAboveCriticalTreatsCriticalAsTheMax() {
        // warning=95, critical=90: an inverted config should never make critical
        // reachable at a lower percent than warning.
        let thresholds = SeverityThresholds(useClaudeSeverity: false, warningPercent: 95, criticalPercent: 90)
        let limit92 = UsageLimit(kind: "session", percent: 92, severity: .normal)
        let limit95 = UsageLimit(kind: "session", percent: 95, severity: .normal)
        #expect(thresholds.resolve(for: limit92) == .normal)
        #expect(thresholds.resolve(for: limit95) == .critical)
    }

    @Test func unknownApiSeverityStillResolvesByPercentInCustomMode() {
        // `.normal` is what unknown/typo'd API severities decode to (see `Severity.init(from:)`);
        // custom mode should ignore it entirely and resolve purely off percent.
        let thresholds = SeverityThresholds(useClaudeSeverity: false, warningPercent: 75, criticalPercent: 90)
        let limit = UsageLimit(kind: "session", percent: 95, severity: .normal)
        #expect(thresholds.resolve(for: limit) == .critical)
    }
}
