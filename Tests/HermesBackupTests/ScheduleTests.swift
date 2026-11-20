import XCTest
@testable import HermesBackup

/// The scheduler against fixed clocks and time zones. These prove the calculation; they don't
/// prove the running app wakes up on time (that's the 1-minute timer plus sleep/wake hooks).
final class ScheduleTests: XCTestCase {
    func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    func at(_ s: String, _ c: Calendar) -> Date {   // "2026-11-18 11:54" in c's zone
        let f = DateFormatter()
        f.calendar = c
        f.timeZone = c.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    let sg = "Asia/Singapore", ny = "America/New_York"

    // MARK: Interval mode (the default)

    func testIntervalCountsFromLastBackup() {
        let c = cal(sg), last = at("2026-11-18 11:54", c)
        let next = Schedule.nextRun(intervalHours: 24, times: nil, lastSuccess: last, now: at("2026-11-18 20:00", c), calendar: c)
        XCTAssertEqual(next, at("2026-11-19 11:52", c))   // 24 h minus the 2-minute early grace
        XCTAssertFalse(Schedule.isDue(intervalHours: 24, times: nil, lastSuccess: last, now: at("2026-11-19 11:50", c), calendar: c))
        XCTAssertTrue(Schedule.isDue(intervalHours: 24, times: nil, lastSuccess: last, now: at("2026-11-19 11:53", c), calendar: c))
    }

    func testNeverBackedUpIsDueNow() {
        let c = cal(sg), now = at("2026-11-18 10:00", c)
        XCTAssertTrue(Schedule.isDue(intervalHours: 1, times: nil, lastSuccess: nil, now: now, calendar: c))
        XCTAssertTrue(Schedule.isDue(intervalHours: 24, times: [TimeOfDay(hour: 9, minute: 0)], lastSuccess: nil, now: now, calendar: c))
    }

    // MARK: Set times

    func testDailySetTimeWaitsForTheTime() {
        let c = cal(sg), t = [TimeOfDay(hour: 21, minute: 0)]
        let last = at("2026-11-17 21:00", c)
        XCTAssertFalse(Schedule.isDue(intervalHours: 24, times: t, lastSuccess: last, now: at("2026-11-18 20:59", c), calendar: c))
        XCTAssertTrue(Schedule.isDue(intervalHours: 24, times: t, lastSuccess: last, now: at("2026-11-18 21:00", c), calendar: c))
        XCTAssertEqual(Schedule.nextRun(intervalHours: 24, times: t, lastSuccess: last, now: at("2026-11-18 12:00", c), calendar: c),
                       at("2026-11-18 21:00", c))
    }

    func testMissedDaysCatchUpOnceNotOncePerDay() {
        let c = cal(sg), t = [TimeOfDay(hour: 9, minute: 0)]
        let woke = at("2026-11-21 14:00", c)   // asleep since the 17th: three 9:00 slots missed
        XCTAssertTrue(Schedule.isDue(intervalHours: 24, times: t, lastSuccess: at("2026-11-17 09:00", c), now: woke, calendar: c))
        // One catch-up backup at 14:00 covers them all; next is tomorrow 9:00, not another run now.
        let after = woke.addingTimeInterval(60)
        XCTAssertFalse(Schedule.isDue(intervalHours: 24, times: t, lastSuccess: woke, now: after, calendar: c))
        XCTAssertEqual(Schedule.nextRun(intervalHours: 24, times: t, lastSuccess: woke, now: after, calendar: c), at("2026-11-22 09:00", c))
    }

    func testTwiceADayPicksTheNearerTime() {
        let c = cal(sg), t = [TimeOfDay(hour: 21, minute: 0), TimeOfDay(hour: 9, minute: 0)]
        let last = at("2026-11-18 09:00", c)
        XCTAssertEqual(Schedule.nextRun(intervalHours: 12, times: t, lastSuccess: last, now: at("2026-11-18 12:00", c), calendar: c),
                       at("2026-11-18 21:00", c))
        XCTAssertEqual(Schedule.nextRun(intervalHours: 12, times: t, lastSuccess: at("2026-11-18 21:00", c),
                                        now: at("2026-11-18 22:00", c), calendar: c),
                       at("2026-11-19 09:00", c))
    }

    func testDuplicateTimesCountOnce() {
        let c = cal(sg), t = [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 9, minute: 0)]
        let last = at("2026-11-18 09:00", c)
        XCTAssertFalse(Schedule.isDue(intervalHours: 12, times: t, lastSuccess: last, now: at("2026-11-18 21:00", c), calendar: c))
        XCTAssertEqual(Schedule.nextRun(intervalHours: 12, times: t, lastSuccess: last, now: at("2026-11-18 21:00", c), calendar: c),
                       at("2026-11-19 09:00", c))
    }

    func testTurningSetTimesOnDoesNotFireAtOnce() {
        // Last backup 12:54 yesterday; at 01:33 set times are switched on with 12:55 AM / 12:55 PM.
        // 12:55 AM already passed, but before the switch, so it isn't "missed".
        let c = cal(sg), t = [TimeOfDay(hour: 12, minute: 55), TimeOfDay(hour: 0, minute: 55)]
        let last = at("2026-11-18 12:54", c), switchedOn = at("2026-11-19 01:33", c)
        XCTAssertTrue(Schedule.isDue(intervalHours: 12, times: t, lastSuccess: last, now: switchedOn, calendar: c),
                      "without the switch-on time it would fire at once")
        XCTAssertFalse(Schedule.isDue(intervalHours: 12, times: t, lastSuccess: last, timesChanged: switchedOn,
                                      now: switchedOn.addingTimeInterval(60), calendar: c))
        XCTAssertEqual(Schedule.nextRun(intervalHours: 12, times: t, lastSuccess: last, timesChanged: switchedOn,
                                        now: switchedOn.addingTimeInterval(60), calendar: c),
                       at("2026-11-19 12:55", c))
    }

    // MARK: Clocks changing

    func testSpringForwardSkippedTimeRunsAtNextValidMoment() {
        // New York, 8 Mar 2026: 2:00 jumps to 3:00, so 2:30 never happens that day.
        let c = cal(ny), t = [TimeOfDay(hour: 2, minute: 30)]
        let next = Schedule.nextRun(intervalHours: 24, times: t, lastSuccess: at("2026-03-07 02:30", c),
                                    now: at("2026-03-07 12:00", c), calendar: c)
        XCTAssertEqual(c.component(.day, from: next), 8)
        XCTAssertEqual(c.component(.hour, from: next), 3)
    }

    func testFallBackRepeatedTimeRunsOnce() {
        // New York, 1 Nov 2026: 1:00–2:00 happens twice. Backed up at the first 1:30;
        // the second 1:30, an hour later, must not run again.
        let c = cal(ny), t = [TimeOfDay(hour: 1, minute: 30)]
        let first = c.nextDate(after: at("2026-11-01 00:00", c), matching: DateComponents(hour: 1, minute: 30),
                               matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)!
        let secondOccurrence = first.addingTimeInterval(3600)
        XCTAssertFalse(Schedule.isDue(intervalHours: 24, times: t, lastSuccess: first, now: secondOccurrence, calendar: c))
        XCTAssertFalse(Schedule.isDue(intervalHours: 24, times: t, lastSuccess: first, now: secondOccurrence.addingTimeInterval(60), calendar: c))
    }

    func testTimeZoneChangeFollowsTheMacsNewClock() {
        // Backed up at 9:00 in Singapore, then flew to New York: 9:00 now means New York's 9:00.
        let t = [TimeOfDay(hour: 9, minute: 0)]
        let last = at("2026-11-18 09:00", cal(sg))
        let c = cal(ny)
        let next = Schedule.nextRun(intervalHours: 24, times: t, lastSuccess: last, now: last.addingTimeInterval(3600), calendar: c)
        XCTAssertEqual(c.component(.hour, from: next), 9)
        XCTAssertEqual(c.component(.minute, from: next), 0)
    }

    // MARK: Settings

    func testOldSettingsFileStillLoads() throws {
        // A settings.json from before set times existed: must keep its destinations.
        let old = #"{"destinations":[{"id":"F8ECD84D-3471-4CDD-8331-F2590AE27A4D","path":"/Users/x/Documents","lastSuccess":"2026-11-18T04:54:12Z"}],"intervalHours":24}"#
        let s = try JSONDecoder.iso.decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(s.destinations.count, 1)
        XCTAssertEqual(s.intervalHours, 24)
        XCTAssertFalse(s.useSetTimes)
        XCTAssertNil(s.activeTimes)
    }

    func testSetTimesOnlyApplyToDailyAndTwiceDaily() {
        var s = Settings()
        s.useSetTimes = true
        s.setTimes = [TimeOfDay(hour: 9, minute: 0), TimeOfDay(hour: 21, minute: 0)]
        s.intervalHours = 4
        XCTAssertNil(s.activeTimes)
        s.intervalHours = 24
        XCTAssertEqual(s.activeTimes, [TimeOfDay(hour: 9, minute: 0)])
        s.intervalHours = 12
        XCTAssertEqual(s.activeTimes?.count, 2)
    }

    func testSuggestedTimeRoundsToFiveMinutes() {
        let c = cal(sg)
        XCTAssertEqual(TimeOfDay(near: at("2026-11-18 11:54", c), calendar: c), TimeOfDay(hour: 11, minute: 55))
        XCTAssertEqual(TimeOfDay(near: at("2026-11-18 23:58", c), calendar: c), TimeOfDay(hour: 0, minute: 0))
    }
}
