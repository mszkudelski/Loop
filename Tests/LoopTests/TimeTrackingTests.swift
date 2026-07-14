import Foundation
import XCTest
@testable import Loop

final class TimeTrackingTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 0)

    func testMergeSortsAndDeduplicatesOverlappingNestedAndAdjacentIntervals() {
        let intervals = [
            interval(20, 30),
            interval(0, 10),
            interval(5, 15),
            interval(0, 10),
            interval(25, 26),
            interval(15, 20),
            interval(40, 50)
        ]

        XCTAssertEqual(
            TimeTracking.mergedIntervals(intervals),
            [interval(0, 30), interval(40, 50)]
        )
    }

    func testMergeClipsBeforeUnionAndDropsEmptyIntersections() {
        let bounds = interval(10, 30)
        let intervals = [
            interval(0, 12),
            interval(11, 20),
            interval(25, 40),
            interval(40, 50)
        ]

        XCTAssertEqual(
            TimeTracking.mergedIntervals(intervals, clippedTo: bounds),
            [interval(10, 20), interval(25, 30)]
        )
    }

    func testTotalDurationCountsTheUnionOnlyOnce() {
        let intervals = [
            interval(0, 10),
            interval(5, 15),
            interval(5, 15),
            interval(20, 25)
        ]

        XCTAssertEqual(TimeTracking.totalDuration(of: intervals), 20, accuracy: 0.000_001)
        XCTAssertEqual(
            TimeTracking.totalDuration(of: intervals, clippedTo: interval(8, 22)),
            9,
            accuracy: 0.000_001
        )
    }

    func testSubtractingUsesBlockedUnionInsteadOfDoubleSubtractingOverlap() {
        let source = [interval(0, 30), interval(5, 10)]
        let blocked = [
            interval(-10, 5),
            interval(3, 10),
            interval(8, 20),
            interval(25, 40)
        ]

        XCTAssertEqual(
            TimeTracking.subtracting(blocked, from: source),
            [interval(20, 25)]
        )
        XCTAssertEqual(
            TimeTracking.exclusiveDuration(of: source, subtracting: blocked),
            5,
            accuracy: 0.000_001
        )
    }

    func testSubtractingAndClippingRemainStableWithDisjointSources() {
        let result = TimeTracking.subtracting(
            [interval(8, 22)],
            from: [interval(0, 10), interval(20, 30)],
            clippedTo: interval(5, 25)
        )

        XCTAssertEqual(result, [interval(5, 8), interval(22, 25)])
    }

    func testClippedIntervalRejectsReversedAndZeroLengthSessions() {
        XCTAssertNil(TimeTracking.clippedInterval(start: date(10), end: date(5)))
        XCTAssertNil(TimeTracking.clippedInterval(start: date(10), end: date(10)))
        XCTAssertNil(
            TimeTracking.clippedInterval(
                start: date(0),
                end: date(10),
                to: interval(10, 20)
            )
        )
        XCTAssertEqual(
            TimeTracking.clippedInterval(
                start: date(0),
                end: date(15),
                to: interval(10, 20)
            ),
            interval(10, 15)
        )
    }

    func testSuspendedGapUsesStrictThresholdAndRejectsClockRollback() {
        XCTAssertNil(
            TimeTracking.suspendedGap(
                from: date(0),
                to: date(120),
                threshold: 120
            )
        )
        XCTAssertEqual(
            TimeTracking.suspendedGap(
                from: date(0),
                to: date(121),
                threshold: 120
            ),
            interval(0, 121)
        )
        XCTAssertNil(
            TimeTracking.suspendedGap(
                from: date(121),
                to: date(0),
                threshold: 120
            )
        )
        XCTAssertNil(
            TimeTracking.suspendedGap(
                from: date(0),
                to: date(121),
                threshold: -1
            )
        )
    }

    func testAwakeClockDetectsSystemSleepButNotBlockedMainThread() {
        XCTAssertEqual(
            TimeTracking.suspendedGap(
                from: date(0),
                to: date(3_605),
                awakeElapsed: 5
            ),
            interval(0, 3_605)
        )
        XCTAssertNil(
            TimeTracking.suspendedGap(
                from: date(0),
                to: date(180),
                awakeElapsed: 179.5
            )
        )
    }

    func testDarkWakeDoesNotBecomeInteractiveUntilScreenWake() {
        var gate = InteractiveActivityGate(
            powerAwake: true,
            screenAwake: true,
            sessionActive: true
        )

        gate.systemWillSleep()
        gate.systemDidWake()
        XCTAssertFalse(gate.isInteractive)

        gate.screenDidWake()
        XCTAssertTrue(gate.isInteractive)
    }

    func testWakeNotificationOrderAndDuplicateEventsAreIdempotent() {
        var gate = InteractiveActivityGate(
            powerAwake: false,
            screenAwake: false,
            sessionActive: true
        )

        gate.screenDidWake()
        gate.systemDidWake()
        gate.systemDidWake()
        XCTAssertTrue(gate.isInteractive)

        gate.sessionDidResign()
        gate.sessionDidResign()
        XCTAssertFalse(gate.isInteractive)

        gate.sessionDidBecomeActive(screenIsAwake: true)
        XCTAssertTrue(gate.isInteractive)
    }

    func testFocusSessionCloseConsumesAnchorExactlyOnce() {
        let taskID = UUID()
        var tracker = FocusSessionTracker()

        XCTAssertTrue(tracker.start(taskID: taskID, at: date(10)))
        XCTAssertFalse(tracker.start(taskID: taskID, at: date(11)))

        let closed = tracker.close(at: date(20))
        XCTAssertEqual(closed?.taskID, taskID)
        XCTAssertEqual(closed?.interval, interval(10, 20))
        XCTAssertNil(tracker.close(at: date(30)))
        XCTAssertFalse(tracker.isOpen)
    }

    func testCrashRecoveryAcceptsOnlyAHeartbeatAtOrBeforeNow() {
        XCTAssertNil(TimeTracking.recoveryEnd(heartbeat: nil, now: date(20)))
        XCTAssertNil(TimeTracking.recoveryEnd(heartbeat: date(21), now: date(20)))
        XCTAssertEqual(TimeTracking.recoveryEnd(heartbeat: date(20), now: date(20)), date(20))
        XCTAssertEqual(TimeTracking.recoveryEnd(heartbeat: date(15), now: date(20)), date(15))
    }

    func testTimerResumePreservesElapsedTimeAndFutureExtensions() {
        XCTAssertEqual(
            TimeTracking.resumedTimerStart(date(5), suspendedAt: date(10), resumedAt: date(110)),
            date(105)
        )
        XCTAssertEqual(
            TimeTracking.resumedTimerStart(date(40), suspendedAt: date(10), resumedAt: date(110)),
            date(140)
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(offset)
    }

    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }
}
