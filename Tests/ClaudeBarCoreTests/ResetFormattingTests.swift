import Testing
import Foundation
@testable import ClaudeBarCore

// Brisbane is UTC+10 with no DST — a fixed, unambiguous zone for asserting the
// core bug fix: UTC instants from the API must render shifted into local time.
private let brisbane = TimeZone(identifier: "Australia/Brisbane")!
private let enAU = Locale(identifier: "en_AU")

// "now" = 2026-07-07T00:00:00Z, i.e. 2026-07-07 10:00 in Brisbane.
private let fixedNow = Date(timeIntervalSince1970: utcEpoch(2026, 7, 7, 0, 0, 0))

struct ResetFormattingTests {
    @Test func sameLocalDayRendersTimeOnly() {
        // 06:20 UTC == 16:20 Brisbane, same calendar day as `fixedNow`'s local day.
        let reset = Date(timeIntervalSince1970: utcEpoch(2026, 7, 7, 6, 20, 0))
        let result = ResetFormatting.localResetString(for: reset, now: fixedNow, timeZone: brisbane, locale: enAU)
        #expect(result.contains("4:20"))
        #expect(!result.contains("Tomorrow"))
    }

    @Test func nextLocalDayIsTomorrow() {
        let reset = Date(timeIntervalSince1970: utcEpoch(2026, 7, 8, 6, 20, 0))
        let result = ResetFormatting.localResetString(for: reset, now: fixedNow, timeZone: brisbane, locale: enAU)
        #expect(result.contains("Tomorrow"))
        #expect(result.contains("4:20"))
    }

    @Test func withinNextWeekUsesWeekdayAbbreviation() {
        // +3 local days from `fixedNow` (July 10, a Friday in Brisbane).
        let reset = Date(timeIntervalSince1970: utcEpoch(2026, 7, 10, 6, 20, 0))
        let result = ResetFormatting.localResetString(for: reset, now: fixedNow, timeZone: brisbane, locale: enAU)
        #expect(result.contains("Fri"))
        #expect(result.contains("4:20"))
    }

    @Test func beyondNextWeekUsesAbbreviatedDate() {
        let reset = Date(timeIntervalSince1970: utcEpoch(2026, 8, 1, 6, 20, 0))
        let result = ResetFormatting.localResetString(for: reset, now: fixedNow, timeZone: brisbane, locale: enAU)
        #expect(result.contains("Aug"))
        #expect(result.contains("4:20"))
    }

    @Test func countdownUnderAMinute() {
        let result = ResetFormatting.countdownString(until: fixedNow.addingTimeInterval(30), now: fixedNow)
        #expect(result == "in <1m")
    }

    @Test func countdownMinutesOnly() {
        let result = ResetFormatting.countdownString(until: fixedNow.addingTimeInterval(12 * 60), now: fixedNow)
        #expect(result == "in 12m")
    }

    @Test func countdownHoursAndMinutes() {
        let interval: TimeInterval = 4 * 3600 + 55 * 60
        let result = ResetFormatting.countdownString(until: fixedNow.addingTimeInterval(interval), now: fixedNow)
        #expect(result == "in 4h 55m")
    }

    @Test func countdownDaysAndHours() {
        let result = ResetFormatting.countdownString(until: fixedNow.addingTimeInterval(50 * 3600), now: fixedNow)
        #expect(result == "in 2d 2h")
    }

    @Test func countdownPastIsResetting() {
        let result = ResetFormatting.countdownString(until: fixedNow.addingTimeInterval(-10), now: fixedNow)
        #expect(result == "resetting…")
    }

    @Test func updatedJustNow() {
        let result = ResetFormatting.updatedAgoString(since: fixedNow.addingTimeInterval(-5), now: fixedNow)
        #expect(result == "Updated just now")
    }

    @Test func updatedSecondsAgo() {
        let result = ResetFormatting.updatedAgoString(since: fixedNow.addingTimeInterval(-25), now: fixedNow)
        #expect(result == "Updated 25s ago")
    }

    @Test func updatedMinutesAgo() {
        let result = ResetFormatting.updatedAgoString(since: fixedNow.addingTimeInterval(-180), now: fixedNow)
        #expect(result == "Updated 3m ago")
    }

    @Test func updatedHoursAgo() {
        let result = ResetFormatting.updatedAgoString(since: fixedNow.addingTimeInterval(-3600), now: fixedNow)
        #expect(result == "Updated 1h ago")
    }
}
