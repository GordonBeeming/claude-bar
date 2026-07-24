import Foundation

/// Renders UTC instants from the API in the viewer's local time — the whole reason
/// this app exists instead of just using the CLI's own usage output. Every function
/// takes `now`/`timeZone`/`locale` as parameters (defaulting to the live values) so
/// tests can pin them and assert deterministically.
public enum ResetFormatting {
    public static func localResetString(
        for date: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        // The API's resets_at carries a little sub-second jitter around the true instant
        // (server-side recomputation noise) that's invisible at the minute granularity
        // this renders at — except when the true instant sits within a second of a
        // minute boundary, where the same reset can otherwise flip its displayed minute
        // from one poll to the next (e.g. 10:09 one refresh, 10:10 the next). Rounding
        // first makes the display stable regardless of which side of the boundary a
        // given poll's jitter lands on.
        let date = roundedToMinute(date)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let time = timeOnly(date, timeZone: timeZone, locale: locale)
        let startOfToday = calendar.startOfDay(for: now)

        guard
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
            let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday),
            let startOfWeekLimit = calendar.date(byAdding: .day, value: 7, to: startOfToday)
        else {
            // Calendar arithmetic overflow is effectively unreachable for realistic
            // dates; fall back to a bare time rather than crashing.
            return time
        }

        if date >= startOfToday && date < startOfTomorrow {
            return time
        }

        if date >= startOfTomorrow && date < startOfDayAfterTomorrow {
            return "Tomorrow \(time)"
        }

        if date >= startOfDayAfterTomorrow && date < startOfWeekLimit {
            let weekday = date.formatted(
                Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated)
            )
            return "\(weekday) \(time)"
        }

        let day = date.formatted(
            Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day()
        )
        return "\(day) \(time)"
    }

    private static func roundedToMinute(_ date: Date) -> Date {
        let seconds = (date.timeIntervalSinceReferenceDate / 60).rounded() * 60
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func timeOnly(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        // `.timeZone(_:)` on FormatStyle adds a timezone *symbol* to the output; the
        // actual rendering timezone has to come from the initializer instead.
        date.formatted(
            Date.FormatStyle(locale: locale, timeZone: timeZone)
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute()
        )
    }

    public static func countdownString(until date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)

        if interval < 0 {
            return "resetting…"
        }
        if interval < 60 {
            return "in <1m"
        }
        if interval < 3600 {
            return "in \(Int(interval / 60))m"
        }
        if interval < 48 * 3600 {
            let hours = Int(interval / 3600)
            let minutes = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
            return "in \(hours)h \(minutes)m"
        }

        let days = Int(interval / 86400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
        return "in \(days)d \(hours)h"
    }

    public static func updatedAgoString(since date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)

        if interval < 10 {
            return "Updated just now"
        }
        if interval < 60 {
            return "Updated \(Int(interval))s ago"
        }
        if interval < 3600 {
            return "Updated \(Int(interval / 60))m ago"
        }
        return "Updated \(Int(interval / 3600))h ago"
    }
}
