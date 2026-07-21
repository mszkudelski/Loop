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

    @MainActor
    func testTimerTextCountsPastZeroInsteadOfStoppingAtDone() {
        XCTAssertEqual(TaskStore.timerText(forRemainingSeconds: 60), "1m")
        XCTAssertEqual(TaskStore.timerText(forRemainingSeconds: 0), "0m")
        XCTAssertEqual(TaskStore.timerText(forRemainingSeconds: -30), "0m")
        XCTAssertEqual(TaskStore.timerText(forRemainingSeconds: -61), "-1m")
        XCTAssertEqual(TaskStore.timerText(forRemainingSeconds: -121), "-2m")
    }

    @MainActor
    func testBreakInterruptsRoutineWithoutCompletingIt() {
        let suiteName = "LoopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TaskStore(defaults: defaults, migrateLegacyDefaults: false)
        store.resumeInteractiveTracking()
        store.addRoutineBlock(title: "Stretch", cadence: .everyLoop)
        let routine = store.routineBlocks[0]

        store.startRoutineBlock(routine)
        XCTAssertTrue(store.isInRoutine)

        store.startBreak()

        XCTAssertFalse(store.isInRoutine)
        XCTAssertTrue(store.isOnBreak)
        XCTAssertEqual(store.routineSessions.last?.routineBlockID, routine.id)
        XCTAssertNil(store.routineBlocks[0].lastCompletedLoop)
        store.suspendTracking()
    }

    @MainActor
    func testMorningRoutineClearsCompletionStateAndBlocksFocusUntilCompleted() {
        let suiteName = "LoopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TaskStore(defaults: defaults, migrateLegacyDefaults: false)
        store.resumeInteractiveTracking()
        store.addTask(title: "First")
        store.addTask(title: "Second")
        let firstTask = store.tasks[0]
        let secondTask = store.tasks[1]
        store.toggleDone(firstTask)

        XCTAssertTrue(store.currentLoopTasks.contains(where: { $0.id == firstTask.id && $0.doneThisLoop }))
        XCTAssertNil(store.currentFocusTaskID)
        store.focus(secondTask)
        XCTAssertNil(store.currentFocusTaskID)
        XCTAssertEqual(store.notice, "Complete the morning routine before focusing a task.")
        let previousLoopNumber = store.loopNumber
        let previousCompletionCount = store.loopCompletions.count

        store.prepareMorningRoutine()

        XCTAssertEqual(store.loopNumber, previousLoopNumber + 1)
        XCTAssertEqual(store.loopCompletions.count, previousCompletionCount)
        XCTAssertTrue(store.currentLoopTasks.allSatisfy { !$0.doneThisLoop })
        XCTAssertNil(store.currentFocusTaskID)

        store.prepareMorningRoutine()

        XCTAssertEqual(store.loopNumber, previousLoopNumber + 1)

        store.markMorningOnboardingShown()

        XCTAssertFalse(store.isMorningRoutineRequired)
        XCTAssertNotNil(store.currentFocusTaskID)
        store.suspendTracking()
    }

    @MainActor
    func testMorningRoutineSettingPersistsAndDisablingItAllowsFocus() {
        let suiteName = "LoopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var store: TaskStore? = TaskStore(defaults: defaults, migrateLegacyDefaults: false)
        store?.resumeInteractiveTracking()
        store?.addTask(title: "Available")
        XCTAssertNil(store?.currentFocusTaskID)

        store?.setMorningRoutineEnabled(false)
        XCTAssertNotNil(store?.currentFocusTaskID)
        store?.flushPendingSave()
        store?.suspendTracking()
        store = nil

        let reloadedStore = TaskStore(defaults: defaults, migrateLegacyDefaults: false)
        XCTAssertFalse(reloadedStore.morningRoutineEnabled)
        XCTAssertNotNil(reloadedStore.currentFocusTaskID)
    }

    @MainActor
    func testAddNowMakesEveryKindOfFutureTaskDueWithoutLosingCompletionHistory() {
        let suiteName = "LoopTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TaskStore(defaults: defaults, migrateLegacyDefaults: false)
        store.addTask(title: "Cadence task", cadence: .everyTwoLoops)
        store.addTask(title: "Keep iteration open")
        let cadenceTask = store.tasks[0]
        store.toggleDone(cadenceTask)
        let completedLoop = store.tasks[0].lastCompletedLoop

        XCTAssertTrue(store.upcomingTasks.contains(where: { $0.id == cadenceTask.id }))

        store.clearSchedule(for: cadenceTask)

        XCTAssertTrue(store.isDue(store.tasks[0]))
        XCTAssertFalse(store.tasks[0].doneThisLoop)
        XCTAssertEqual(store.tasks[0].lastCompletedLoop, completedLoop)
        XCTAssertTrue(store.currentLoopTasks.contains(where: { $0.id == cadenceTask.id }))

        store.addTask(title: "Next iteration", addToCurrentIteration: false)
        let futureTask = store.tasks.last!
        XCTAssertFalse(store.isDue(futureTask))

        store.clearSchedule(for: futureTask)

        XCTAssertTrue(store.isDue(store.tasks.last!))
        XCTAssertTrue(store.currentLoopTasks.contains(where: { $0.id == futureTask.id }))
    }

    func testFocusTimeIsOffByDefault() {
        let schedule = FocusTimeSchedule()

        XCTAssertFalse(schedule.contains(localDate(hour: 8)))
        XCTAssertFalse(schedule.includesRoutines)
        XCTAssertTrue(schedule.allowsBreaks)
        XCTAssertFalse(schedule.confirmsMeetings)
    }

    func testLegacyFocusTimeSettingsReceiveCurrentPolicyDefaults() throws {
        let data = Data(#"""
        {
            "isEnabled": true,
            "startTime": { "hour": 7, "minute": 0 },
            "endTime": { "hour": 10, "minute": 0 }
        }
        """#.utf8)

        let schedule = try JSONDecoder().decode(FocusTimeSchedule.self, from: data)

        XCTAssertTrue(schedule.isEnabled)
        XCTAssertFalse(schedule.includesRoutines)
        XCTAssertTrue(schedule.allowsBreaks)
        XCTAssertFalse(schedule.confirmsMeetings)
    }

    func testFocusTimePolicyRoundTripsThroughPersistence() throws {
        let schedule = FocusTimeSchedule(
            isEnabled: true,
            includesRoutines: true,
            allowsBreaks: false,
            confirmsMeetings: true
        )

        let restored = try JSONDecoder().decode(
            FocusTimeSchedule.self,
            from: JSONEncoder().encode(schedule)
        )

        XCTAssertEqual(restored, schedule)
    }

    func testFocusTimeIncludesStartAndExcludesEnd() {
        let schedule = FocusTimeSchedule(
            isEnabled: true,
            startTime: DailyScheduleTime(hour: 7),
            endTime: DailyScheduleTime(hour: 10)
        )

        XCTAssertFalse(schedule.contains(localDate(hour: 6, minute: 59)))
        XCTAssertTrue(schedule.contains(localDate(hour: 7)))
        XCTAssertTrue(schedule.contains(localDate(hour: 9, minute: 59)))
        XCTAssertFalse(schedule.contains(localDate(hour: 10)))
    }

    func testFocusTimeCanCrossMidnight() {
        let schedule = FocusTimeSchedule(
            isEnabled: true,
            startTime: DailyScheduleTime(hour: 22),
            endTime: DailyScheduleTime(hour: 2)
        )

        XCTAssertTrue(schedule.contains(localDate(hour: 23)))
        XCTAssertTrue(schedule.contains(localDate(hour: 1)))
        XCTAssertFalse(schedule.contains(localDate(hour: 12)))
    }

    func testFocusTimeFindsEndOfCurrentDaytimeBlock() {
        let schedule = FocusTimeSchedule(
            isEnabled: true,
            startTime: DailyScheduleTime(hour: 7),
            endTime: DailyScheduleTime(hour: 10)
        )

        XCTAssertEqual(
            schedule.endOfActiveBlock(containing: localDate(hour: 8)),
            localDate(hour: 10)
        )
        XCTAssertNil(schedule.endOfActiveBlock(containing: localDate(hour: 12)))
    }

    func testFocusTimeFindsEndOfOvernightBlockOnEitherSideOfMidnight() {
        let schedule = FocusTimeSchedule(
            isEnabled: true,
            startTime: DailyScheduleTime(hour: 22),
            endTime: DailyScheduleTime(hour: 2)
        )

        XCTAssertEqual(
            schedule.endOfActiveBlock(containing: localDate(day: 15, hour: 23)),
            localDate(day: 16, hour: 2)
        )
        XCTAssertEqual(
            schedule.endOfActiveBlock(containing: localDate(day: 15, hour: 1)),
            localDate(day: 15, hour: 2)
        )
    }

    func testEqualFocusTimeBoundsDoNotCreateAllDayFocus() {
        let schedule = FocusTimeSchedule(
            isEnabled: true,
            startTime: DailyScheduleTime(hour: 7),
            endTime: DailyScheduleTime(hour: 7)
        )

        XCTAssertFalse(schedule.contains(localDate(hour: 7)))
        XCTAssertFalse(schedule.contains(localDate(hour: 12)))
    }

    @MainActor
    func testIterationDurationsUseConsecutiveCompletionTimes() {
        let completions = [
            LoopCompletion(loopNumber: 3, completedAt: date(300)),
            LoopCompletion(loopNumber: 1, completedAt: date(0)),
            LoopCompletion(loopNumber: 2, completedAt: date(120))
        ]

        XCTAssertEqual(TaskStore.iterationDurations(for: completions), [120, 180])
    }

    @MainActor
    func testIterationDurationsFilterByTheIterationCompletionTime() {
        let completions = [
            LoopCompletion(loopNumber: 1, completedAt: date(0)),
            LoopCompletion(loopNumber: 2, completedAt: date(120)),
            LoopCompletion(loopNumber: 3, completedAt: date(300))
        ]

        XCTAssertEqual(
            TaskStore.iterationDurations(
                for: completions,
                completedIn: DateInterval(start: date(200), end: date(400))
            ),
            [180]
        )
    }

    @MainActor
    func testLegacyIterationDurationRequiresTwoCompletions() {
        XCTAssertEqual(
            TaskStore.iterationDurations(
                for: [LoopCompletion(loopNumber: 1, completedAt: date(0))]
            ),
            []
        )
    }

    @MainActor
    func testRecordedIterationStartProvidesFirstDuration() {
        let completion = LoopCompletion(
            loopNumber: 1,
            startedAt: date(30),
            completedAt: date(120)
        )

        XCTAssertEqual(TaskStore.iterationDurations(for: [completion]), [90])
    }

    @MainActor
    func testLegacyDurationsIgnoreSkippedIterationNumbers() {
        let completions = [
            LoopCompletion(loopNumber: 1, completedAt: date(0)),
            LoopCompletion(loopNumber: 3, completedAt: date(300))
        ]

        XCTAssertEqual(TaskStore.iterationDurations(for: completions), [])
    }

    @MainActor
    func testActiveIterationDurationCountsOnlyTrackedActiveTime() {
        let completions = [
            LoopCompletion(loopNumber: 1, startedAt: date(0), completedAt: date(90)),
            LoopCompletion(loopNumber: 2, startedAt: date(90), completedAt: date(240))
        ]
        let activeIntervals = [
            interval(0, 30),
            interval(60, 120),
            interval(180, 240)
        ]

        XCTAssertEqual(
            TaskStore.activeIterationDurations(
                for: completions,
                activeIntervals: activeIntervals
            ),
            [60, 90]
        )
    }

    @MainActor
    func testIterationDurationDoesNotSpanCalendarDays() {
        let completion = LoopCompletion(
            loopNumber: 1,
            startedAt: localDate(day: 15, hour: 23),
            completedAt: localDate(day: 16, hour: 1)
        )

        XCTAssertEqual(TaskStore.iterationDurations(for: [completion]), [])
    }

    private func date(_ offset: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(offset)
    }

    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }

    private func localDate(day: Int = 15, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = Calendar.current.timeZone
        components.year = 2026
        components.month = 7
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}
