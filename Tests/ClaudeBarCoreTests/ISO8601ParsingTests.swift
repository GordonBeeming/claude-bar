import Testing
import Foundation
@testable import ClaudeBarCore

struct ISO8601ParsingTests {
    @Test func sixDigitFractionalSecondsWithOffset() {
        let parsed = ISO8601Parsing.parse("2026-07-07T06:20:00.010527+00:00")
        #expect(parsed != nil)
        guard let parsed else { return }
        let expected = utcEpoch(2026, 7, 7, 6, 20, 0, fraction: 0.010527)
        // Millisecond-truncation fallback can drop sub-millisecond precision.
        #expect(abs(parsed.timeIntervalSince1970 - expected) < 0.01)
    }

    @Test func noFractionalSeconds() {
        let parsed = ISO8601Parsing.parse("2026-07-07T06:20:00+00:00")
        #expect(parsed != nil)
        guard let parsed else { return }
        let expected = utcEpoch(2026, 7, 7, 6, 20, 0)
        #expect(abs(parsed.timeIntervalSince1970 - expected) < 0.001)
    }

    @Test func zSuffix() {
        let parsed = ISO8601Parsing.parse("2026-07-07T06:20:00.500Z")
        #expect(parsed != nil)
        guard let parsed else { return }
        let expected = utcEpoch(2026, 7, 7, 6, 20, 0, fraction: 0.5)
        #expect(abs(parsed.timeIntervalSince1970 - expected) < 0.01)
    }

    @Test func nonUTCOffset() {
        // 16:20 at +10:00 is the same instant as 06:20 UTC.
        let parsed = ISO8601Parsing.parse("2026-07-07T16:20:00+10:00")
        #expect(parsed != nil)
        guard let parsed else { return }
        let expected = utcEpoch(2026, 7, 7, 6, 20, 0)
        #expect(abs(parsed.timeIntervalSince1970 - expected) < 0.001)
    }

    @Test func garbageReturnsNil() {
        #expect(ISO8601Parsing.parse("not-a-date") == nil)
        #expect(ISO8601Parsing.parse("") == nil)
    }
}

func utcEpoch(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, fraction: Double = 0) -> Double {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    guard let date = calendar.date(from: components) else {
        preconditionFailure("invalid fixture date components")
    }
    return date.timeIntervalSince1970 + fraction
}
