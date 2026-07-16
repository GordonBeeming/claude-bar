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

/// The snapshot-dict key the detector looks up — mirrors `UsageLimit.celebrationKey` for
/// the fields the test helper sets (model id is always nil here).
private func celebKey(_ kind: String, model: String? = nil) -> String {
    [kind, "", model ?? ""].joined(separator: "\u{1}")
}

struct CelebrationEventTests {
    @Test func firstSeenLimitNeverFires() {
        // No previous snapshot → nothing fires, even though usage/resetsAt look eventful.
        let session = limit(id: "session", group: "session", percent: 2, resetsAt: fixedNow.addingTimeInterval(5 * 3600))
        let events = detectCelebrationEvents(previous: [:], current: [session], now: fixedNow)
        #expect(events.isEmpty)
    }

    @Test func sessionResetFiresWhenLowUsageReturnsToZero() {
        let session = limit(id: "session", group: "session", percent: 0, resetsAt: fixedNow.addingTimeInterval(5 * 3600))
        let previous = [celebKey("session"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 20, overPaceLatched: false)]
        #expect(detectCelebrationEvents(previous: previous, current: [session], now: fixedNow) == [.sessionReset])
    }

    @Test func usageClimbIsNotAReset() {
        // Usage rising within a window is the normal case — never a reset.
        let reset = fixedNow.addingTimeInterval(2 * 3600)
        let session = limit(id: "session", group: "session", percent: 40, resetsAt: reset)
        let previous = [celebKey("session"): LimitSnapshot(resetsAt: reset, percent: 30, overPaceLatched: false)]
        #expect(detectCelebrationEvents(previous: previous, current: [session], now: fixedNow).isEmpty)
    }

    @Test func smallDropIsNotAReset() {
        // A 20-point dip (40% → 20%) doesn't clear the 25-point threshold.
        let session = limit(id: "session", group: "session", percent: 20, resetsAt: fixedNow.addingTimeInterval(2 * 3600))
        let previous = [celebKey("session"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(2 * 3600), percent: 40, overPaceLatched: false)]
        #expect(detectCelebrationEvents(previous: previous, current: [session], now: fixedNow).isEmpty)
    }

    @Test func dropNotBelowFloorIsNotAReset() {
        // A big drop (90% → 30%) that doesn't land under 10% isn't a reset — a reset empties
        // the window. overPace already true → no over-pace edge, isolating the reset check.
        let weekly = limit(id: "weekly_all", group: "weekly", percent: 30, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let previous = [celebKey("weekly_all"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(7 * 86400), percent: 90, overPaceLatched: true)]
        #expect(detectCelebrationEvents(previous: previous, current: [weekly], now: fixedNow).isEmpty)
    }

    @Test func weeklyResetFiresWhenLowUsageReturnsToZero() {
        let weekly = limit(id: "weekly_all", group: "weekly", percent: 0, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let previous = [celebKey("weekly_all"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(7 * 86400), percent: 20, overPaceLatched: true)]
        #expect(detectCelebrationEvents(previous: previous, current: [weekly], now: fixedNow) == [.weeklyReset])
    }

    @Test func weeklyResetCanAlsoFireOverPace() {
        let weekly = limit(id: "weekly_all", group: "weekly", percent: 9, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let previous = [celebKey("weekly_all"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(7 * 86400), percent: 95, overPaceLatched: true)]
        #expect(detectCelebrationEvents(previous: previous, current: [weekly], now: fixedNow) == [.weeklyReset, .overWeeklyPace])
    }

    @Test func simultaneousWeeklyResetsDedupeToOne() {
        // The all-models weekly and a model-scoped weekly reset together → one trigger. They
        // have distinct celebration keys, so neither is treated as ambiguous.
        let weeklyAll = limit(id: "weekly_all", group: "weekly", percent: 0, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let weeklyFable = limit(id: "weekly_scoped", group: "weekly", percent: 0, resetsAt: fixedNow.addingTimeInterval(7 * 86400), model: "Fable")
        let previous = [
            celebKey("weekly_all"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 90, overPaceLatched: false),
            celebKey("weekly_scoped", model: "Fable"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 50, overPaceLatched: false)
        ]
        let events = detectCelebrationEvents(previous: previous, current: [weeklyAll, weeklyFable], now: fixedNow)
        #expect(events == [.weeklyReset])
    }

    @Test func collidingScopedLimitsDoNotFirePhantomReset() {
        // Two scoped weekly limits with no model name collapse to the same celebration key.
        // A high-% previous snapshot vs a different low-% current limit looks like a reset,
        // but the pair is indistinguishable, so the detector skips both rather than guess.
        let a = limit(id: "weekly_scoped", group: "weekly", percent: 5, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let b = limit(id: "weekly_scoped", group: "weekly", percent: 8, resetsAt: fixedNow.addingTimeInterval(7 * 86400))
        let previous = [celebKey("weekly_scoped"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(-3600), percent: 90, overPaceLatched: false)]
        #expect(detectCelebrationEvents(previous: previous, current: [a, b], now: fixedNow).isEmpty)
    }

    @Test func resetsAtJumpWithoutUsageDropIsNotAReset() {
        // The old phantom: resetsAt lurches a whole week further out while usage is unchanged.
        // Usage didn't drop, so it must not fire a reset.
        let future = fixedNow.addingTimeInterval(5 * 86400)
        let weekly = limit(id: "weekly_all", group: "weekly", percent: 25,
                           resetsAt: future.addingTimeInterval(7 * 86400))
        let previous = [celebKey("weekly_all"): LimitSnapshot(resetsAt: future, percent: 25, overPaceLatched: true)]
        #expect(!detectCelebrationEvents(previous: previous, current: [weekly], now: fixedNow).contains(.weeklyReset))
    }

    @Test func overPaceFiresOnRisingEdgeOnly() {
        // 60% used at 50% elapsed → over pace now. Previous snapshot was not over pace → edge.
        let weekly = limit(id: "weekly_all", group: "weekly", percent: 60, resetsAt: fixedNow.addingTimeInterval(3.5 * 86400))
        let notYet = [celebKey("weekly_all"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(3.5 * 86400), percent: 45, overPaceLatched: false)]
        #expect(detectCelebrationEvents(previous: notYet, current: [weekly], now: fixedNow) == [.overWeeklyPace])

        // Already over pace last poll → no repeat fire.
        let already = [celebKey("weekly_all"): LimitSnapshot(resetsAt: fixedNow.addingTimeInterval(3.5 * 86400), percent: 55, overPaceLatched: true)]
        #expect(detectCelebrationEvents(previous: already, current: [weekly], now: fixedNow).isEmpty)
    }

    @Test func overPaceRearmsOnlyAfterClearlyUnderPace() {
        let duration = 7 * 86400.0
        let weekly = limit(
            id: "weekly_all",
            group: "weekly",
            percent: 60,
            resetsAt: fixedNow.addingTimeInterval(duration / 2)
        )

        let first = LimitSnapshot.next(after: nil, for: weekly, now: fixedNow)
        let nearBoundaryTime = fixedNow.addingTimeInterval(duration * 0.105) // 0.5 points under pace.
        let nearBoundary = LimitSnapshot.next(
            after: first,
            for: weekly,
            now: nearBoundaryTime
        )
        let clearlyUnderTime = fixedNow.addingTimeInterval(duration * 0.12) // 2 points under pace.
        let clearlyUnder = LimitSnapshot.next(
            after: nearBoundary,
            for: weekly,
            now: clearlyUnderTime
        )
        let reentered = limit(
            id: "weekly_all",
            group: "weekly",
            percent: 63,
            resetsAt: weekly.resetsAt
        )

        #expect(first.overPaceLatched)
        #expect(nearBoundary.overPaceLatched)
        #expect(!clearlyUnder.overPaceLatched)
        #expect(detectCelebrationEvents(
            previous: [celebKey("weekly_all"): clearlyUnder],
            current: [reentered],
            now: clearlyUnderTime
        ) == [.overWeeklyPace])
    }
}
