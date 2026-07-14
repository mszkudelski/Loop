import Foundation

/// Pure date-interval arithmetic used by time tracking.
///
/// All returned intervals have a positive duration. Overlapping, duplicate, and
/// directly adjacent intervals are treated as one continuous span so persisted
/// session duplicates cannot inflate duration totals.
enum TimeTracking {
    static func clippedInterval(
        start: Date,
        end: Date,
        to bounds: DateInterval? = nil
    ) -> DateInterval? {
        guard end > start else { return nil }
        return clipped(DateInterval(start: start, end: end), to: bounds)
    }

    static func clipped(
        _ interval: DateInterval,
        to bounds: DateInterval?
    ) -> DateInterval? {
        guard interval.end > interval.start else { return nil }
        guard let bounds else { return interval }

        let start = max(interval.start, bounds.start)
        let end = min(interval.end, bounds.end)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func mergedIntervals(
        _ intervals: [DateInterval],
        clippedTo bounds: DateInterval? = nil
    ) -> [DateInterval] {
        let sortedIntervals = intervals
            .compactMap { clipped($0, to: bounds) }
            .sorted {
                if $0.start == $1.start {
                    return $0.end < $1.end
                }
                return $0.start < $1.start
            }

        return sortedIntervals.reduce(into: [DateInterval]()) { result, interval in
            guard let previous = result.last else {
                result.append(interval)
                return
            }

            guard interval.start <= previous.end else {
                result.append(interval)
                return
            }

            result[result.count - 1] = DateInterval(
                start: previous.start,
                end: max(previous.end, interval.end)
            )
        }
    }

    static func totalDuration(
        of intervals: [DateInterval],
        clippedTo bounds: DateInterval? = nil
    ) -> TimeInterval {
        mergedIntervals(intervals, clippedTo: bounds).reduce(0) { total, interval in
            total + interval.duration
        }
    }

    static func subtracting(
        _ blockedIntervals: [DateInterval],
        from sourceIntervals: [DateInterval],
        clippedTo bounds: DateInterval? = nil
    ) -> [DateInterval] {
        let sources = mergedIntervals(sourceIntervals, clippedTo: bounds)
        let blocked = mergedIntervals(blockedIntervals, clippedTo: bounds)
        guard !sources.isEmpty, !blocked.isEmpty else { return sources }

        return sources.flatMap { source in
            var result: [DateInterval] = []
            var cursor = source.start

            for excluded in blocked {
                if excluded.end <= cursor {
                    continue
                }
                if excluded.start >= source.end {
                    break
                }

                if excluded.start > cursor {
                    result.append(DateInterval(
                        start: cursor,
                        end: min(excluded.start, source.end)
                    ))
                }

                cursor = max(cursor, excluded.end)
                if cursor >= source.end {
                    break
                }
            }

            if cursor < source.end {
                result.append(DateInterval(start: cursor, end: source.end))
            }
            return result
        }
    }

    static func exclusiveDuration(
        of sourceIntervals: [DateInterval],
        subtracting blockedIntervals: [DateInterval],
        clippedTo bounds: DateInterval? = nil
    ) -> TimeInterval {
        subtracting(blockedIntervals, from: sourceIntervals, clippedTo: bounds)
            .reduce(0) { $0 + $1.duration }
    }

    /// Returns the full unobserved tick span when it is longer than the allowed
    /// timer delay. A strict comparison keeps a tick exactly at the threshold
    /// classified as active time.
    static func suspendedGap(
        from previousTick: Date,
        to currentTick: Date,
        threshold: TimeInterval
    ) -> DateInterval? {
        guard threshold >= 0, currentTick > previousTick else { return nil }
        guard currentTick.timeIntervalSince(previousTick) > threshold else { return nil }
        return DateInterval(start: previousTick, end: currentTick)
    }

    /// Detects time when the wall clock advanced but the system's awake clock
    /// did not. This distinguishes actual system sleep from a busy or blocked
    /// main thread, where both clocks continue to advance together.
    static func suspendedGap(
        from previousTick: Date,
        to currentTick: Date,
        awakeElapsed: TimeInterval,
        tolerance: TimeInterval = 2
    ) -> DateInterval? {
        guard tolerance >= 0, awakeElapsed >= 0, currentTick > previousTick else { return nil }
        let wallElapsed = currentTick.timeIntervalSince(previousTick)
        guard wallElapsed - awakeElapsed > tolerance else { return nil }
        return DateInterval(start: previousTick, end: currentTick)
    }

    /// A persisted heartbeat may bound crash recovery only when it is not in
    /// the future. Time after this boundary is intentionally treated as
    /// suspended because the process no longer proved that it was running.
    static func recoveryEnd(heartbeat: Date?, now: Date) -> Date? {
        guard let heartbeat, heartbeat <= now else { return nil }
        return heartbeat
    }

    /// Moves an iteration timer across a proven suspended span. Timer starts
    /// may legitimately be in the future after an extension, so every timer
    /// that existed at suspension moves by the same duration.
    static func resumedTimerStart(
        _ timerStart: Date,
        suspendedAt: Date,
        resumedAt: Date
    ) -> Date {
        guard resumedAt > suspendedAt else { return timerStart }
        return timerStart.addingTimeInterval(resumedAt.timeIntervalSince(suspendedAt))
    }
}

/// Non-persisted lifecycle facts used to distinguish an interactive wake from
/// macOS maintenance/DarkWake activity.
struct InteractiveActivityGate: Equatable {
    var powerAwake: Bool
    var screenAwake: Bool
    var sessionActive: Bool

    var isInteractive: Bool {
        powerAwake && screenAwake && sessionActive
    }

    mutating func systemWillSleep() {
        powerAwake = false
        screenAwake = false
    }

    mutating func systemDidWake() {
        powerAwake = true
    }

    mutating func screenDidSleep() {
        screenAwake = false
    }

    mutating func screenDidWake() {
        powerAwake = true
        screenAwake = true
    }

    mutating func sessionDidResign() {
        sessionActive = false
    }

    mutating func sessionDidBecomeActive(screenIsAwake: Bool) {
        sessionActive = true
        screenAwake = screenIsAwake
        if screenIsAwake {
            powerAwake = true
        }
    }
}

/// Runtime-only owner of an open task-focus interval. Closing consumes the
/// anchor before returning, making duplicate or out-of-order close events safe.
struct FocusSessionTracker: Equatable {
    private(set) var taskID: UUID?
    private(set) var startedAt: Date?

    var isOpen: Bool {
        taskID != nil && startedAt != nil
    }

    @discardableResult
    mutating func start(taskID: UUID, at date: Date) -> Bool {
        guard !isOpen else { return false }
        self.taskID = taskID
        startedAt = date
        return true
    }

    mutating func close(at date: Date) -> (taskID: UUID, interval: DateInterval)? {
        guard let taskID, let startedAt else {
            reset()
            return nil
        }
        reset()
        guard date > startedAt else { return nil }
        return (taskID, DateInterval(start: startedAt, end: date))
    }

    mutating func reset() {
        taskID = nil
        startedAt = nil
    }
}
