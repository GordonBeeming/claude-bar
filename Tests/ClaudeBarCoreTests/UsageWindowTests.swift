import Testing
import Foundation
@testable import ClaudeBarCore

// "now" = 2026-07-07T12:00:00Z, arbitrary but fixed so every test reasons about
// the same instant. (`utcEpoch` comes from ISO8601ParsingTests.swift.)
private let fixedNow = Date(timeIntervalSince1970: utcEpoch(2026, 7, 7, 12, 0, 0))

private func limit(
    group: String?,
    percent: Double,
    resetsAt: Date?
) -> UsageLimit {
    UsageLimit(kind: "test", group: group, percent: percent, severity: .normal, resetsAt: resetsAt)
}

struct UsageWindowTests {
    @Test func durationPerGroup() {
        #expect(UsageWindow.duration(forGroup: "session") == TimeInterval(5 * 3600))
        #expect(UsageWindow.duration(forGroup: "weekly") == TimeInterval(7 * 86400))
        #expect(UsageWindow.duration(forGroup: "other") == nil)
        #expect(UsageWindow.duration(forGroup: nil) == nil)
    }

    @Test func paceFractionNilForUnknownGroup() {
        let unknownGroup = limit(group: "other", percent: 50, resetsAt: fixedNow.addingTimeInterval(3600))
        #expect(UsageWindow.paceFraction(for: unknownGroup, now: fixedNow) == nil)
    }

    @Test func paceFractionNilWithoutResetsAt() {
        let noReset = limit(group: "session", percent: 50, resetsAt: nil)
        #expect(UsageWindow.paceFraction(for: noReset, now: fixedNow) == nil)
    }

    @Test func paceFractionHalfwayThroughSession() {
        // resetsAt 2h30m from now, 5h window → 2h30m has already elapsed → 0.5.
        let halfway = limit(group: "session", percent: 60, resetsAt: fixedNow.addingTimeInterval(2.5 * 3600))
        let fraction = UsageWindow.paceFraction(for: halfway, now: fixedNow)
        #expect(fraction != nil)
        if let fraction {
            #expect(abs(fraction - 0.5) < 0.0001)
        }
    }

    @Test func paceFractionClampsBelowZero() {
        // resetsAt far beyond the window's own duration from now → the window
        // hasn't started yet from `now`'s perspective → clamps to 0, not negative.
        let notStarted = limit(group: "session", percent: 10, resetsAt: fixedNow.addingTimeInterval(10 * 3600))
        #expect(UsageWindow.paceFraction(for: notStarted, now: fixedNow) == 0)
    }

    @Test func paceFractionClampsAboveOne() {
        // resetsAt already in the past → the window's fully elapsed → clamps to 1.
        let alreadyPast = limit(group: "session", percent: 90, resetsAt: fixedNow.addingTimeInterval(-3600))
        #expect(UsageWindow.paceFraction(for: alreadyPast, now: fixedNow) == 1)
    }

    @Test func isOverPaceTrueWhenAheadOfLine() {
        // Halfway through (50% elapsed), 60% used → past the pace line → over pace.
        let ahead = limit(group: "session", percent: 60, resetsAt: fixedNow.addingTimeInterval(2.5 * 3600))
        #expect(UsageWindow.isOverPace(for: ahead, now: fixedNow))
    }

    @Test func isOverPaceFalseAtOrBelowLine() {
        // Exactly on the line (50% used, 50% elapsed) and behind it (40%) are both not over pace.
        let onPace = limit(group: "session", percent: 50, resetsAt: fixedNow.addingTimeInterval(2.5 * 3600))
        #expect(!UsageWindow.isOverPace(for: onPace, now: fixedNow))
        let behind = limit(group: "session", percent: 40, resetsAt: fixedNow.addingTimeInterval(2.5 * 3600))
        #expect(!UsageWindow.isOverPace(for: behind, now: fixedNow))
    }

    @Test func isOverPaceRespectsExplicitMargin() {
        // 53% used at 50% elapsed → 3 points ahead: over the bare line, but inside a 5% buffer.
        let slightlyAhead = limit(group: "session", percent: 53, resetsAt: fixedNow.addingTimeInterval(2.5 * 3600))
        #expect(UsageWindow.isOverPace(for: slightlyAhead, now: fixedNow))
        #expect(!UsageWindow.isOverPace(for: slightlyAhead, now: fixedNow, marginPercent: 5))
    }

    @Test func isOverPaceFalseForUnknownGroup() {
        let unknownGroup = limit(group: "other", percent: 99, resetsAt: fixedNow.addingTimeInterval(60))
        #expect(!UsageWindow.isOverPace(for: unknownGroup, now: fixedNow))
    }
}
