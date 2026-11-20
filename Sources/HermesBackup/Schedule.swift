import Foundation

/// A time of day on this Mac's clock, e.g. 21:00.
struct TimeOfDay: Codable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { (a.hour, a.minute) < (b.hour, b.minute) }

    var components: DateComponents { DateComponents(hour: hour, minute: minute, second: 0) }

    /// Rounded to the nearest 5 minutes, as a starting suggestion.
    init(near date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let total = ((c.hour ?? 9) * 60 + (c.minute ?? 0) + 2) / 5 * 5 % (24 * 60)
        hour = total / 60
        minute = total % 60
    }

    init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }

    func adding(hours: Int) -> TimeOfDay { TimeOfDay(hour: (hour + hours) % 24, minute: minute) }
}

/// When a backup is due. Pure, so it can be tested with any clock and time zone; the app and the
/// "Next backup" line both read it, so what's shown is what runs.
///
/// Two modes:
/// - Interval (the default, and the only mode for hourly / 4-hourly): `interval` after the last success.
/// - Set times (daily / twice daily, opt-in): each listed time on this Mac's local clock. A slot that
///   passed while the Mac slept or the app was closed is made up once, never once per missed slot.
enum Schedule {
    /// Allows a scheduled interval backup to start up to 2 minutes early, so the 1-minute check
    /// doesn't push each run later and later.
    static let earlyGrace: TimeInterval = 120

    /// `timesChanged`: when set times were last switched on or edited. Slots before it don't count
    /// as missed, so turning the setting on (or moving a time earlier) never fires a backup at once.
    static func nextRun(intervalHours: Int, times: [TimeOfDay]?, lastSuccess: Date?,
                        timesChanged: Date? = nil,
                        now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        guard let last = lastSuccess else { return now }
        let slots = Array(Set(times ?? [])).sorted()
        guard !slots.isEmpty else {
            return last.addingTimeInterval(Double(intervalHours) * 3600 - earlyGrace)
        }
        let covered = max(last, timesChanged ?? .distantPast)
        // A slot at or before now that no backup has covered yet: run now.
        if let recent = mostRecentSlot(slots, atOrBefore: now, calendar: calendar), recent > covered {
            return recent
        }
        return slots.compactMap { next($0, after: now, calendar: calendar) }.min() ?? now
    }

    static func isDue(intervalHours: Int, times: [TimeOfDay]?, lastSuccess: Date?,
                      timesChanged: Date? = nil,
                      now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        nextRun(intervalHours: intervalHours, times: times, lastSuccess: lastSuccess,
                timesChanged: timesChanged, now: now, calendar: calendar) <= now
    }

    /// `.nextTime`: a time skipped by a daylight-saving jump runs at the next valid moment.
    /// `.first`: a time that happens twice when clocks go back counts once, at its first occurrence.
    private static func next(_ t: TimeOfDay, after date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: date, matching: t.components, matchingPolicy: .nextTime,
                          repeatedTimePolicy: .first, direction: .forward)
    }

    private static func mostRecentSlot(_ slots: [TimeOfDay], atOrBefore date: Date, calendar: Calendar) -> Date? {
        // Look back from just after `date`, so a slot exactly at `date` counts.
        slots.compactMap { t -> Date? in
            guard let found = calendar.nextDate(after: date.addingTimeInterval(1), matching: t.components,
                                                matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                                direction: .backward) else { return nil }
            // Searching backwards lands on the LATER copy of a time that happens twice when clocks
            // go back (ignoring `.first`), which would run a second backup an hour after the first.
            // A day's slot is always its first occurrence, found forwards from that day's start.
            let dayStart = calendar.startOfDay(for: found)
            let d = next(t, after: dayStart.addingTimeInterval(-1), calendar: calendar) ?? found
            return d <= date ? d : nil
        }.max()
    }
}
