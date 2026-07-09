import Testing
import Foundation
@testable import ClaudeBarCore

private let fixedNow = Date(timeIntervalSince1970: utcEpoch(2026, 7, 7, 12, 0, 0))

private func limit(
    id kind: String,
    group: String?,
    percent: Double,
    resetsAt: Date?,
    model: String? = nil
) -> UsageLimit {
    let scope = model.map { LimitScope(model: .init(displayName: $0)) }
    return UsageLimit(kind: kind, group: group, percent: percent, severity: .normal, resetsAt: resetsAt, scope: scope)
}

struct CelebrationEventTests {
    @Test func firstSeenLimitNeverFires() {
        // No previous snapshot → nothing fires, even though resetsAt/usage look eventful.
        let session = limit(id: "session", group: "session", percent: 2, resetsAt: fixedNow.addingTimeInterval(5 * 3600))
        let events = detectCelebrationEvents(previous: [:], current: [session], now: fixedNow)
        #expect(events.isEmpty)
    }

    @Test func sessionResetFiresOnForwardJump() {
        let session = limit(id: "session", group: "session", percent: 1, resetsAt: fixedNow.addingTimeInterval(5 * 3600))
        // Previous window ended an hour ago; the new one ends 5h out → rolled over.
        let previous = ["session": LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 88, overPace: false)]
        let events = detectCelebrationEvents(previous: previous, current: [session], now: fixedNow)
        #expect(events == [.sessionReset])
    }

    @Test func noResetWhenResetsAtUnchanged() {
        let reset = fixedNow.addingTimeInterval(2 * 3600)
        let session = limit(id: "session", group: "session", percent: 40, resetsAt: reset)
        let previous = ["session": LimitSnapshot(resetsAt: reset, percent: 30, overPace: false)]
        #expect(detectCelebrationEvents(previous: previous, current: [session], now: fixedNow).isEmpty)
    }

    @Test func smallResetsAtDriftIsNotAReset() {
        // A few seconds of forward jitter in `resetsAt` must not read as a reset — a real
        // rollover jumps by most of the window, not a handful of seconds.
        let base = fixedNow.addingTimeInterval(2 * 3600)
        let drifted = limit(id: "session", group: "session", percent: 41, resetsAt: base.addingTimeInterval(3))
        let previous = ["session": LimitSnapshot(resetsAt: base, percent: 40, overPace: false)]
        #expect(detectCelebrationEvents(previous: previous, current: [drifted], now: fixedNow).isEmpty)
    }

    @Test func weeklyResetRoutesToWeeklyTrigger() {
        let weekly = limit(id: "weekly_all", group: "weekly", percent: 1, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let previous = ["weekly_all": LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 95, overPace: true)]
        #expect(detectCelebrationEvents(previous: previous, current: [weekly], now: fixedNow) == [.weeklyReset])
    }

    @Test func simultaneousWeeklyResetsDedupeToOne() {
        // The all-models weekly and a model-scoped weekly reset together → one trigger.
        let weeklyAll = limit(id: "weekly_all", group: "weekly", percent: 0, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let weeklyFable = limit(id: "weekly_scoped", group: "weekly", percent: 0, resetsAt: fixedNow.addingTimeInterval(7 * 86400), model: "Fable")
        let previous = [
            "weekly_all": LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 90, overPace: false),
            "weekly_scopedFable": LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 50, overPace: false)
        ]
        let events = detectCelebrationEvents(previous: previous, current: [weeklyAll, weeklyFable], now: fixedNow)
        #expect(events == [.weeklyReset])
    }

    @Test func overPaceFiresOnRisingEdgeOnly() {
        // 60% used at 50% elapsed → over pace now. Previous snapshot was not over pace → edge.
        let weekly = limit(id: "weekly_all", group: "weekly", percent: 60, resetsAt: fixedNow.addingTimeInterval(3.5 * 86400))
        let notYet = ["weekly_all": LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(3.5 * 86400), percent: 45, overPace: false)]
        #expect(detectCelebrationEvents(previous: notYet, current: [weekly], now: fixedNow) == [.overWeeklyPace])

        // Already over pace last poll → no repeat fire.
        let already = ["weekly_all": LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(3.5 * 86400), percent: 55, overPace: true)]
        #expect(detectCelebrationEvents(previous: already, current: [weekly], now: fixedNow).isEmpty)
    }
}
