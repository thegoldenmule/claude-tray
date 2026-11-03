import Foundation
import Testing
@testable import ClaudeTray

private let chicago: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

/// A local date in Chicago.
private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    chicago.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private let hour: TimeInterval = 3600
private let weekdays = PaceSettings(countWeekends: false, tolerance: 10)
private let allDays = PaceSettings(countWeekends: true, tolerance: 10)

@Suite struct WorkTimeTests {
    // Wed 2026-10-28 04:00 → Wed 2026-11-04 04:00 (spans the 2026-11-01 DST change).
    let start = date(2026, 10, 28, 4)
    let end = date(2026, 11, 4, 4)

    @Test func weekdaysOnlyCountsFiveDays() {
        let work = WorkTime(countWeekends: false, calendar: chicago)
        // Wed 20h + Thu + Fri + Mon + Tue + Wed 4h; the 25-hour DST Sunday is skipped.
        #expect(work.seconds(from: start, to: end) == 120 * hour)
    }

    @Test func allDaysCountsRealElapsedTime() {
        let work = WorkTime(countWeekends: true, calendar: chicago)
        #expect(work.seconds(from: start, to: end) == end.timeIntervalSince(start))
        #expect(end.timeIntervalSince(start) == 169 * hour) // DST ends: one extra hour
    }

    @Test func addingWorkingSecondsSkipsTheWeekend() {
        let work = WorkTime(countWeekends: false, calendar: chicago)
        // From Fri 20:00, 10 working hours: 4h on Friday, then 6h into Monday.
        let result = work.date(addingWorkingSeconds: 10 * hour, to: date(2026, 10, 30, 20), limit: end)
        #expect(result == date(2026, 11, 2, 6))
        #expect(work.date(addingWorkingSeconds: 200 * hour, to: start, limit: end) == nil)
    }

    @Test func nextWorkingStart() {
        let work = WorkTime(countWeekends: false, calendar: chicago)
        #expect(work.nextWorkingStart(after: date(2026, 10, 31, 12), limit: end) == date(2026, 11, 2))
        #expect(work.nextWorkingStart(after: date(2026, 10, 31, 12), limit: date(2026, 11, 1, 10)) == nil)
    }
}

@Suite struct WeeklyPaceTests {
    @Test func liveResponseIsWellUnderPace() throws {
        // The real window: 40% used, Tue 10:54 local, five weekdays of 24h from Wed 04:00.
        let pace = try #require(WeeklyPace.compute(used: 40,
                                                   windowStart: date(2026, 10, 28, 4),
                                                   resetsAt: date(2026, 11, 4, 4),
                                                   now: date(2026, 11, 3, 10, 54),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(abs(pace.expected - 85.75) < 0.01)
        #expect(pace.status == .under)
        #expect(pace.severity == .calm)
        #expect(pace.runsOutAt == nil)
        #expect(pace.pausedUntil == nil)
        #expect(pace.menuBarLabel == "\u{2212}46")
    }

    @Test func halfUsedAfterOneOfFiveDaysIsWayOver() throws {
        // The example from the request: a Mon–Mon window, one weekday gone, 50% used.
        let pace = try #require(WeeklyPace.compute(used: 50,
                                                   windowStart: date(2026, 11, 2),
                                                   resetsAt: date(2026, 11, 9),
                                                   now: date(2026, 11, 3),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(abs(pace.expected - 20) < 0.001)
        #expect(pace.status == .over)
        #expect(pace.menuBarLabel == "+30")
        // 50% per 24 working hours: the other 50% is gone 24 hours later.
        #expect(pace.runsOutAt == date(2026, 11, 4))
        #expect(pace.severity == .critical)
        #expect(abs(pace.projectedAtReset! - 250) < 0.001)
    }

    @Test func countingWeekendsLowersTheExpectedValueOnWeekdays() throws {
        let pace = try #require(WeeklyPace.compute(used: 50,
                                                   windowStart: date(2026, 11, 2),
                                                   resetsAt: date(2026, 11, 9),
                                                   now: date(2026, 11, 3),
                                                   settings: allDays,
                                                   calendar: chicago))
        #expect(abs(pace.expected - 100.0 / 7) < 0.001)
        #expect(pace.pausedUntil == nil)
    }

    @Test func earlyDoubleSpeedIsNotOnPace() throws {
        // 12 of 120 weekday hours: expected 10%. 19% is only 9 points over, but it's 1.9×
        // the even rate: it runs out more than two working days early.
        let pace = try #require(WeeklyPace.compute(used: 19,
                                                   windowStart: date(2026, 11, 2),
                                                   resetsAt: date(2026, 11, 9),
                                                   now: date(2026, 11, 2, 12),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(abs(pace.expected - 10) < 0.001)
        #expect(pace.status == .over)
        #expect(pace.severity == .critical)
        #expect(pace.menuBarLabel == "+9")

        // 11% projects to 110%: still on pace at ±10%.
        let close = try #require(WeeklyPace.compute(used: 11,
                                                    windowStart: date(2026, 11, 2),
                                                    resetsAt: date(2026, 11, 9),
                                                    now: date(2026, 11, 2, 12),
                                                    settings: weekdays,
                                                    calendar: chicago))
        #expect(close.status == .onTrack)
    }

    @Test func toleranceScalesWithExpected() throws {
        // Expected 90%: the band is ±9 points, so 80% is under but 82% is on pace.
        func status(_ used: Double) throws -> PaceStatus {
            try #require(WeeklyPace.compute(used: used, windowStart: date(2026, 11, 2), resetsAt: date(2026, 11, 9),
                                            now: date(2026, 11, 6, 12), settings: weekdays, calendar: chicago)).status
        }
        #expect(try status(80) == .under)
        #expect(try status(82) == .onTrack)
        #expect(try status(98) == .onTrack)
        #expect(try status(99.5) == .over)
    }

    @Test func slightlyOverIsAWarning() throws {
        // Three of five days gone: expected 60%. 71% used runs out ~19 working hours early.
        let pace = try #require(WeeklyPace.compute(used: 71,
                                                   windowStart: date(2026, 11, 2),
                                                   resetsAt: date(2026, 11, 9),
                                                   now: date(2026, 11, 5),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(pace.status == .over)
        #expect(pace.runsOutAt != nil)
        #expect(pace.lockedOutWorkTime! < WeeklyPace.criticalLockout)
        #expect(pace.severity == .warning)
    }

    @Test func underPaceDoesNotRunOut() throws {
        // 4.5 of 5 days: expected 90%, used 75% → 15 under.
        let pace = try #require(WeeklyPace.compute(used: 75,
                                                   windowStart: date(2026, 11, 2),
                                                   resetsAt: date(2026, 11, 9),
                                                   now: date(2026, 11, 6, 12),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(pace.status == .under)
        #expect(pace.runsOutAt == nil)
        #expect(pace.severity == .calm)
    }

    @Test func onTrackWithinTolerance() throws {
        let pace = try #require(WeeklyPace.compute(used: 45,
                                                   windowStart: date(2026, 11, 2),
                                                   resetsAt: date(2026, 11, 9),
                                                   now: date(2026, 11, 4, 12),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(abs(pace.expected - 50) < 0.001)
        #expect(pace.status == .onTrack)
        #expect(pace.menuBarLabel == "✓")
        #expect(abs(pace.projectedAtReset! - 90) < 0.001)
    }

    @Test func weekendPausesPace() throws {
        let saturday = try #require(WeeklyPace.compute(used: 50,
                                                       windowStart: date(2026, 10, 28, 4),
                                                       resetsAt: date(2026, 11, 4, 4),
                                                       now: date(2026, 10, 31, 12),
                                                       settings: weekdays,
                                                       calendar: chicago))
        let sunday = try #require(WeeklyPace.compute(used: 50,
                                                     windowStart: date(2026, 10, 28, 4),
                                                     resetsAt: date(2026, 11, 4, 4),
                                                     now: date(2026, 11, 1, 20),
                                                     settings: weekdays,
                                                     calendar: chicago))
        #expect(saturday.expected == sunday.expected)
        #expect(abs(saturday.expected - 100 * 68 / 120) < 0.001) // Wed 20h + Thu + Fri of 120h
        #expect(saturday.pausedUntil == date(2026, 11, 2))
    }

    @Test func tooEarlyRightAfterReset() throws {
        let pace = try #require(WeeklyPace.compute(used: 1,
                                                   windowStart: date(2026, 11, 2, 9),
                                                   resetsAt: date(2026, 11, 9, 9),
                                                   now: date(2026, 11, 2, 10),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(pace.status == .tooEarly)
        #expect(pace.projectedAtReset == nil)
        #expect(pace.menuBarLabel == "1%")
    }

    @Test func clearlyOverEvenWhenEarly() throws {
        let pace = try #require(WeeklyPace.compute(used: 25,
                                                   windowStart: date(2026, 11, 2, 9),
                                                   resetsAt: date(2026, 11, 9, 9),
                                                   now: date(2026, 11, 2, 10),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(pace.status == .over)
    }

    @Test func limitReached() throws {
        let pace = try #require(WeeklyPace.compute(used: 100,
                                                   windowStart: date(2026, 11, 2),
                                                   resetsAt: date(2026, 11, 9),
                                                   now: date(2026, 11, 5),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(pace.status == .limitReached)
        #expect(pace.severity == .critical)
        #expect(pace.menuBarLabel == "100%")
        #expect(pace.runsOutAt == nil)
    }

    @Test func noWorkingTimeLeft() throws {
        // The window resets Saturday 05:00 and it's Saturday 02:00: no weekday time is left.
        let pace = try #require(WeeklyPace.compute(used: 60,
                                                   windowStart: date(2026, 10, 31, 5),
                                                   resetsAt: date(2026, 11, 7, 5),
                                                   now: date(2026, 11, 7, 2),
                                                   settings: weekdays,
                                                   calendar: chicago))
        #expect(pace.expected == 100)
        #expect(pace.pausedUntil == date(2026, 11, 7, 5))
    }

    @Test func nilAfterReset() {
        #expect(WeeklyPace.compute(used: 40, windowStart: date(2026, 11, 2), resetsAt: date(2026, 11, 9),
                                   now: date(2026, 11, 9, 1), settings: weekdays, calendar: chicago) == nil)
    }
}
