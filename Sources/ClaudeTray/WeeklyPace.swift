import Foundation

/// User preferences for weekly pacing.
struct PaceSettings: Sendable, Equatable {
    /// Count Saturday and Sunday as working time. Off by default: the weekly budget is
    /// paced across weekdays only.
    var countWeekends = false
    /// On pace means the current rate ends the week within this many percent of the budget
    /// (100% ± tolerance), so the allowed gap scales with the expected value: ±1 point when
    /// 10% is expected, ±9 when 90% is.
    var tolerance: Double = 10

    static let toleranceChoices: [Double] = [5, 10, 20]
}

/// What the menu bar item shows.
enum MenuBarMode: String, CaseIterable, Sendable {
    /// Session usage when the account has a session limit, otherwise weekly pace. Also
    /// switches to weekly when the weekly limit is about to run out.
    case auto
    case session
    case weekly

    var title: String {
        switch self {
        case .auto: "Auto"
        case .session: "Session"
        case .weekly: "Weekly pace"
        }
    }
}

/// UserDefaults keys shared by the menu bar label and the panel.
enum SettingsKey {
    static let countWeekends = "paceCountWeekends"
    static let tolerance = "paceTolerance"
    static let menuBarMode = "menuBarMode"
}

// MARK: - Working time

/// Measures time that counts toward pacing: every hour, or only hours on weekdays
/// (by the calendar's own weekend definition and time zone).
struct WorkTime: Sendable {
    var countWeekends: Bool
    var calendar: Calendar

    func isWorking(_ date: Date) -> Bool {
        countWeekends || !calendar.isDateInWeekend(date)
    }

    /// Working seconds in `[from, to)`.
    func seconds(from start: Date, to end: Date) -> TimeInterval {
        guard end > start else { return 0 }
        if countWeekends { return end.timeIntervalSince(start) }
        var total: TimeInterval = 0
        forEachDay(from: start, to: end) { segmentStart, segmentEnd in
            if isWorking(segmentStart) { total += segmentEnd.timeIntervalSince(segmentStart) }
            return true
        }
        return total
    }

    /// The moment `amount` working seconds after `start`, or nil if that's at or after `limit`.
    func date(addingWorkingSeconds amount: TimeInterval, to start: Date, limit: Date) -> Date? {
        guard amount >= 0 else { return nil }
        var left = amount
        var result: Date?
        forEachDay(from: start, to: limit) { segmentStart, segmentEnd in
            guard isWorking(segmentStart) else { return true }
            let length = segmentEnd.timeIntervalSince(segmentStart)
            if length > left {
                result = segmentStart.addingTimeInterval(left)
                return false
            }
            left -= length
            return true
        }
        return result
    }

    /// The start of the next working day after `date`, if it's before `limit`.
    func nextWorkingStart(after date: Date, limit: Date) -> Date? {
        var result: Date?
        forEachDay(from: date, to: limit) { segmentStart, _ in
            if segmentStart > date, isWorking(segmentStart) {
                result = segmentStart
                return false
            }
            return true
        }
        return result
    }

    /// Calls `body` with each piece of `[start, end)` cut at local midnights, until it
    /// returns false. Uses the calendar (not 86 400 s) so DST days are 23 or 25 hours.
    private func forEachDay(from start: Date, to end: Date, _ body: (Date, Date) -> Bool) {
        var cursor = start
        while cursor < end {
            guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)),
                  nextMidnight > cursor else { return }
            let segmentEnd = min(nextMidnight, end)
            guard body(cursor, segmentEnd) else { return }
            cursor = segmentEnd
        }
    }
}

// MARK: - Pace

enum PaceStatus: Sendable, Equatable {
    case tooEarly       // not enough working time has passed to judge
    case under
    case onTrack
    case over
    case limitReached
}

/// How urgent the pace is; drives colour in the menu bar and panel.
enum PaceSeverity: Sendable, Equatable {
    case calm
    case warning        // over pace
    case critical       // at the limit, or projected to hit it a working day or more before reset
}

/// Where weekly usage stands against an even spend of the budget over the window's
/// working time.
struct WeeklyPace: Sendable, Equatable {
    /// Percent of the weekly budget used.
    var used: Double
    /// Percent that would be used by now at an even pace.
    var expected: Double
    var status: PaceStatus
    var resetsAt: Date
    /// Working time left before reset.
    var workRemaining: TimeInterval
    /// Average % per working hour so far this window.
    var averageRate: Double?
    /// Percent used at reset if the average rate continues.
    var projectedAtReset: Double?
    /// When usage reaches 100% at the average rate, if that's before reset.
    var runsOutAt: Date?
    /// Working time between `runsOutAt` and reset.
    var lockedOutWorkTime: TimeInterval?
    /// Set while `now` isn't working time (a weekend with weekdays-only pacing): when pacing
    /// resumes, or `resetsAt` if it doesn't before then.
    var pausedUntil: Date?

    /// Percentage points over (+) or under (−) the expected value.
    var delta: Double { used - expected }

    var severity: PaceSeverity {
        switch status {
        case .limitReached: .critical
        case .over: (lockedOutWorkTime ?? 0) >= Self.criticalLockout ? .critical : .warning
        case .tooEarly, .under, .onTrack: .calm
        }
    }

    /// Over pace turns critical when the projection runs out at least this much working
    /// time (a working day) before reset.
    static let criticalLockout: TimeInterval = 24 * 3600
    /// The on-pace band is never narrower than this many points, so tiny early values don't flicker.
    static let minimumBand: Double = 2
    /// Minimum working time before over/under is judged, unless usage is already more
    /// than `tolerance` points over.
    static let minimumElapsed: TimeInterval = 2 * 3600
    static let minimumExpected: Double = 3
    /// The average rate (and projections from it) need at least this much working time.
    static let minimumRateElapsed: TimeInterval = 3600
    /// Nil when the window is over (or malformed) or has no working time at all.
    static func compute(used: Double,
                        windowStart: Date,
                        resetsAt: Date,
                        now: Date,
                        settings: PaceSettings,
                        calendar: Calendar = .current) -> WeeklyPace? {
        guard resetsAt > windowStart, now < resetsAt, used.isFinite else { return nil }
        let work = WorkTime(countWeekends: settings.countWeekends, calendar: calendar)
        let total = work.seconds(from: windowStart, to: resetsAt)
        guard total > 0 else { return nil }
        let clampedNow = max(now, windowStart)
        let elapsed = work.seconds(from: windowStart, to: clampedNow)
        let remaining = max(0, total - elapsed)
        let expected = 100 * elapsed / total
        let delta = used - expected

        let status: PaceStatus
        let band = max(Self.minimumBand, settings.tolerance * expected / 100)
        if used >= 100 {
            status = .limitReached
        } else if elapsed < minimumElapsed || expected < minimumExpected {
            status = delta > settings.tolerance ? .over : .tooEarly
        } else if delta > band {
            status = .over
        } else if delta < -band {
            status = .under
        } else {
            status = .onTrack
        }

        let averageRate = elapsed >= minimumRateElapsed ? max(0, used) / (elapsed / 3600) : nil

        var projectedAtReset: Double?
        var runsOutAt: Date?
        var lockedOutWorkTime: TimeInterval?
        if status != .limitReached, status != .tooEarly, let averageRate {
            projectedAtReset = used + averageRate * remaining / 3600
            if averageRate > 0, let projected = projectedAtReset, projected >= 100 {
                let secondsLeft = (100 - used) / averageRate * 3600
                runsOutAt = work.date(addingWorkingSeconds: secondsLeft, to: clampedNow, limit: resetsAt)
                if runsOutAt != nil { lockedOutWorkTime = remaining - secondsLeft }
            }
        }

        let pausedUntil = work.isWorking(clampedNow)
            ? nil
            : (work.nextWorkingStart(after: clampedNow, limit: resetsAt) ?? resetsAt)

        return WeeklyPace(used: used,
                          expected: expected,
                          status: status,
                          resetsAt: resetsAt,
                          workRemaining: remaining,
                          averageRate: averageRate,
                          projectedAtReset: projectedAtReset,
                          runsOutAt: runsOutAt,
                          lockedOutWorkTime: lockedOutWorkTime,
                          pausedUntil: pausedUntil)
    }
}
