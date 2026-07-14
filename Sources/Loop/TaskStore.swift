import AppKit
import Combine
import Foundation

enum LoopTaskSuggestion: String, Codable, Equatable {
    case editCadence
    case markPriority
    case snoozeAfterQuickDone

    var message: String {
        switch self {
        case .editCadence:
            "You have snoozed this a few times. Make it show up less often?"
        case .markPriority:
            "You keep focusing this one. Mark it priority?"
        case .snoozeAfterQuickDone:
            "That was quick. Park it for the next pass?"
        }
    }

    var actionTitle: String {
        switch self {
        case .editCadence:
            "Edit cadence"
        case .markPriority:
            "Mark priority"
        case .snoozeAfterQuickDone:
            "Snooze 30m"
        }
    }

    var systemImage: String {
        switch self {
        case .editCadence:
            "repeat"
        case .markPriority:
            "star"
        case .snoozeAfterQuickDone:
            "clock"
        }
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [LoopTask] = [] {
        didSet { save() }
    }

    @Published private(set) var loopNumber: Int = 1 {
        didSet { save() }
    }

    @Published private(set) var loopCompletions: [LoopCompletion] = [] {
        didSet { save() }
    }

    @Published private(set) var breakSessions: [BreakSession] = [] {
        didSet { save() }
    }

    @Published private(set) var meetingSessions: [MeetingSession] = [] {
        didSet { save() }
    }

    @Published private(set) var routineBlocks: [RoutineBlock] = [] {
        didSet { save() }
    }

    @Published private(set) var routineSessions: [RoutineSession] = [] {
        didSet { save() }
    }

    @Published private(set) var activeSessions: [ActiveSession] = [] {
        didSet { save() }
    }

    @Published private(set) var taskFocusSessions: [TaskFocusSession] = [] {
        didSet { save() }
    }

    @Published private(set) var actionCounts: [String: Int] = [:] {
        didSet { save() }
    }

    @Published private(set) var shortcut: KeyboardShortcutSetting = .defaultShortcut
    @Published private(set) var doneShortcut: KeyboardShortcutSetting = .defaultDoneShortcut
    @Published private(set) var quickAddShortcut: KeyboardShortcutSetting = .defaultQuickAddShortcut
    @Published private(set) var breakShortcut: KeyboardShortcutSetting = .defaultBreakShortcut
    @Published private(set) var breakDurationMinutes = 5 {
        didSet { save() }
    }
    @Published private(set) var defaultIterationTimerMinutes = 2 {
        didSet { save() }
    }
    @Published private(set) var newTasksStartInCurrentIteration = true {
        didSet { save() }
    }

    @Published private(set) var focusedTaskID: UUID? {
        didSet { save() }
    }

    @Published private(set) var autoOpenFocusedTaskApp = true {
        didSet { save() }
    }

    @Published private(set) var openLoopAtLogin = LoginLaunchAgent.isEnabled

    @Published private(set) var dismissedFastLoopSuggestionAt: Date? {
        didSet { save() }
    }

    @Published private(set) var morningOnboardingShownAt: Date? {
        didSet { save() }
    }

    @Published private(set) var breakStartedAt: Date? {
        didSet { save() }
    }

    @Published private(set) var breakUntil: Date? {
        didSet { save() }
    }

    @Published private(set) var breakShouldFocusPriorityAfterBreak = false {
        didSet { save() }
    }

    @Published private(set) var meetingStartedAt: Date? {
        didSet { save() }
    }

    @Published private(set) var activeRoutineBlockID: UUID? {
        didSet { save() }
    }

    @Published private(set) var activeRoutineStartedAt: Date? {
        didSet { save() }
    }

    @Published private(set) var activeRoutineUntil: Date? {
        didSet { save() }
    }

    @Published private(set) var activeRoutineScheduledAt: Date? {
        didSet { save() }
    }

    @Published private(set) var activeStartedAt: Date? {
        didSet { save() }
    }

    @Published private(set) var sleepStartedAt: Date? {
        didSet { save() }
    }

    @Published private(set) var currentDate = Date()

    @Published var notice: String?

    var onShortcutChange: ((KeyboardShortcutSetting) -> Void)?
    var onDoneShortcutChange: ((KeyboardShortcutSetting) -> Void)?
    var onQuickAddShortcutChange: ((KeyboardShortcutSetting) -> Void)?
    var onBreakShortcutChange: ((KeyboardShortcutSetting) -> Void)?
    var onSuspensionDetected: (() -> Void)?

    private let defaultsKey = "Loop.store.v1"
    private let fastLoopCompletionThreshold: TimeInterval = 2 * 60
    private let fastLoopSuggestionWindow: TimeInterval = 10 * 60
    private let quickCompletionThreshold: TimeInterval = 20
    private let quickCompletionSuggestionWindow: TimeInterval = 10 * 60
    private let trackingHeartbeatInterval: TimeInterval = 30
    private let maximumRecoveredRoutineDuration: TimeInterval = 6 * 60 * 60
    private var openingTaskIDs = Set<UUID>()
    private var lastAutoOpenedFocusedTaskID: UUID?
    private var snoozeRefreshTimer: Timer?
    private var countdownRefreshTimer: Timer?
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var focusSessionTracker = FocusSessionTracker()
    private var isInteractiveTrackingEnabled = false
    private var lastTrackingTickDate = Date()
    private var lastAwakeUptime = ProcessInfo.processInfo.systemUptime
    private var trackingHeartbeatAt: Date?
    private var isLoading = false

    init() {
        load()
        startSnoozeRefreshTimer()
        startCountdownRefreshTimer()
    }

    var activeTasks: [LoopTask] {
        orderedForIteration(tasks.filter { !$0.isBacklog && !$0.finished && !$0.doneThisLoop && isDue($0) && !isSnoozed($0) })
    }

    var actionTelemetry: [ActionTelemetryStat] {
        LoopAction.allCases.map { action in
            ActionTelemetryStat(
                id: action.rawValue,
                title: action.title,
                count: actionCounts[action.rawValue] ?? 0,
                systemImage: action.systemImage,
                category: action.category
            )
        }
        .sorted {
            if $0.count == $1.count {
                return $0.title < $1.title
            }
            return $0.count > $1.count
        }
    }

    var currentLoopTasks: [LoopTask] {
        orderedForIteration(tasks.filter { !$0.isBacklog && !$0.finished && ($0.doneThisLoop || (isDue($0) && !isSnoozed($0))) })
    }

    var currentFocusTaskID: UUID? {
        guard !isOnBreak, !isInMeeting else { return nil }
        let currentTasks = currentLoopTasks

        if let focusedTaskID,
           currentTasks.contains(where: { $0.id == focusedTaskID && !$0.doneThisLoop }) {
            return focusedTaskID
        }

        return firstUndoneCurrentTaskID()
    }

    var focusedTaskTitle: String? {
        focusedTask?.title
    }

    var focusedTask: LoopTask? {
        guard
            let currentFocusTaskID,
            let task = tasks.first(where: { $0.id == currentFocusTaskID })
        else {
            return nil
        }

        return task
    }

    var focusedTaskTimerText: String? {
        guard
            let focusedTask,
            let remainingSeconds = iterationTimerRemainingSeconds(for: focusedTask)
        else {
            return nil
        }

        return Self.timerText(forRemainingSeconds: remainingSeconds)
    }

    var isOnBreak: Bool {
        breakStartedAt != nil
    }

    var isInMeeting: Bool {
        meetingStartedAt != nil
    }

    var isInRoutine: Bool {
        activeRoutineBlockID != nil && activeRoutineStartedAt != nil
    }

    var activeRoutineBlock: RoutineBlock? {
        guard let activeRoutineBlockID else { return nil }
        return routineBlocks.first { $0.id == activeRoutineBlockID }
    }

    var dueRoutineBlocks: [RoutineBlock] {
        orderedRoutines(routineBlocks.filter(isRoutineDue))
    }

    var openRoutineBlocks: [RoutineBlock] {
        var routines = dueRoutineBlocks
        if let activeRoutineBlock,
           !routines.contains(where: { $0.id == activeRoutineBlock.id }) {
            routines.append(activeRoutineBlock)
        }
        return orderedRoutines(routines)
    }

    var isBreakTimeUp: Bool {
        guard isOnBreak, let breakUntil else { return false }
        return breakUntil <= currentDate
    }

    var breakRemainingSeconds: Int {
        guard let breakUntil else { return 0 }
        return max(0, Int(ceil(breakUntil.timeIntervalSince(currentDate))))
    }

    var breakTimerText: String? {
        guard isOnBreak else { return nil }
        if isBreakTimeUp {
            return "Break done"
        }
        let minutes = max(0, Int(ceil(Double(breakRemainingSeconds) / 60.0)))
        return "Break \(minutes)m"
    }

    var breakDurationSeconds: TimeInterval {
        TimeInterval(breakDurationMinutes * 60)
    }

    var meetingElapsedSeconds: Int {
        guard let meetingStartedAt else { return 0 }
        return max(0, Int(currentDate.timeIntervalSince(meetingStartedAt)))
    }

    var meetingTimerText: String? {
        guard isInMeeting else { return nil }
        return "In meeting · \(elapsedMeetingDurationText)"
    }

    var isRoutineTimeUp: Bool {
        guard isInRoutine, let activeRoutineUntil else { return false }
        return activeRoutineUntil <= currentDate
    }

    var routineRemainingSeconds: Int {
        guard let activeRoutineUntil else { return 0 }
        return max(0, Int(ceil(activeRoutineUntil.timeIntervalSince(currentDate))))
    }

    var routineTimerText: String? {
        guard isInRoutine, let activeRoutineBlock else { return nil }
        if isRoutineTimeUp {
            return "\(activeRoutineBlock.title) done"
        }
        let minutes = max(0, Int(ceil(Double(routineRemainingSeconds) / 60.0)))
        return "\(activeRoutineBlock.title) \(minutes)m"
    }

    private var elapsedMeetingDurationText: String {
        let elapsedSeconds = meetingElapsedSeconds
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }

    var defaultIterationTimerMinutesOrNil: Int? {
        normalizedIterationTimerMinutes(defaultIterationTimerMinutes)
    }

    var doneTasks: [LoopTask] {
        tasks
            .filter { task in
                guard !task.isBacklog else { return false }
                if task.finished {
                    return task.finishedLoop == loopNumber
                }
                if task.doneThisLoop {
                    return true
                }
                return false
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var doneRoutineBlocks: [RoutineBlock] {
        orderedRoutines(routineBlocks.filter { routine in
            guard routine.isEnabled else { return false }
            if routine.lastCompletedLoop == loopNumber {
                return true
            }
            if let lastCompletedScheduledAt = routine.lastCompletedScheduledAt {
                return Calendar.current.isDate(lastCompletedScheduledAt, inSameDayAs: currentDate)
            }
            return false
        })
    }

    var upcomingTasks: [LoopTask] {
        tasks
            .filter { task in
                guard !task.isBacklog, !task.finished else { return false }
                if task.scheduledFor.map({ $0 > currentDate }) == true {
                    return true
                }
                if isSnoozed(task) {
                    return true
                }
                if !isDue(task), !task.doneThisLoop {
                    return true
                }
                if task.doneThisLoop, task.cadence.rawValue > 1 {
                    return true
                }
                return false
            }
            .sorted {
                let leftScheduledDate = activeScheduledDate(for: $0) ?? .distantFuture
                let rightScheduledDate = activeScheduledDate(for: $1) ?? .distantFuture
                if leftScheduledDate != rightScheduledDate {
                    return leftScheduledDate < rightScheduledDate
                }

                let leftSnoozeDate = activeSnoozeDate(for: $0) ?? .distantFuture
                let rightSnoozeDate = activeSnoozeDate(for: $1) ?? .distantFuture
                if leftSnoozeDate != rightSnoozeDate {
                    return leftSnoozeDate < rightSnoozeDate
                }

                let leftDueLoop = nextDueLoop(for: $0) ?? Int.max
                let rightDueLoop = nextDueLoop(for: $1) ?? Int.max
                if leftDueLoop == rightDueLoop {
                    return isOrderedBefore($0, $1)
                }
                return leftDueLoop < rightDueLoop
            }
    }

    var finishedTasks: [LoopTask] {
        tasks
            .filter(\.finished)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var backlogTasks: [LoopTask] {
        ordered(tasks.filter { $0.isBacklog && !$0.finished })
    }

    var loopsCompletedToday: Int {
        loopsCompleted(on: Date())
    }

    var loopsCompletedTotal: Int {
        loopCompletions.count
    }

    var daysActiveTotal: Int {
        Set(loopCompletions.map { Calendar.current.startOfDay(for: $0.completedAt) }).count
    }

    var tasksFinishedToday: [LoopTask] {
        tasksFinished(on: Date())
    }

    func loopsCompleted(on date: Date) -> Int {
        loopCompletions.filter { Calendar.current.isDate($0.completedAt, inSameDayAs: date) }.count
    }

    func loopsCompleted(in interval: DateInterval) -> Int {
        loopCompletions.filter { interval.contains($0.completedAt) }.count
    }

    func tasksFinished(on date: Date) -> [LoopTask] {
        finishedTasks.filter { task in
            guard let finishedAt = task.finishedAt else { return false }
            return Calendar.current.isDate(finishedAt, inSameDayAs: date)
        }
    }

    func tasksFinished(in interval: DateInterval) -> [LoopTask] {
        finishedTasks.filter { task in
            guard let finishedAt = task.finishedAt else { return false }
            return interval.contains(finishedAt)
        }
    }

    var breakCountTotal: Int {
        breakSessions.count + (isOnBreak ? 1 : 0)
    }

    var meetingCountTotal: Int {
        meetingSessions.count + (isInMeeting ? 1 : 0)
    }

    var routineCountTotal: Int {
        routineSessions.count + (isInRoutine ? 1 : 0)
    }

    var breakDurationTotal: TimeInterval {
        effectiveBreakDuration(in: nil)
    }

    var meetingDurationTotal: TimeInterval {
        duration(of: mergedIntervals(meetingIntervals(in: nil)))
    }

    var routineDurationTotal: TimeInterval {
        routineDuration(in: nil)
    }

    var productiveRoutineDurationTotal: TimeInterval {
        productiveRoutineDuration(in: nil)
    }

    var activeDurationTotal: TimeInterval {
        activeWorkDuration(in: nil)
    }

    var productiveDurationTotal: TimeInterval {
        activeDurationTotal + productiveRoutineDurationTotal
    }

    func breakCount(on date: Date) -> Int {
        let completedCount = breakSessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }.count
        let activeCount = breakStartedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } == true ? 1 : 0
        return completedCount + activeCount
    }

    func breakCount(in interval: DateInterval) -> Int {
        let completedCount = breakSessions.filter { interval.contains($0.startedAt) }.count
        let activeCount = breakStartedAt.map { interval.contains($0) } == true ? 1 : 0
        return completedCount + activeCount
    }

    func breakDuration(on date: Date) -> TimeInterval {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return 0 }
        return breakDuration(in: interval)
    }

    func breakDuration(in interval: DateInterval) -> TimeInterval {
        effectiveBreakDuration(in: interval)
    }

    func meetingCount(on date: Date) -> Int {
        let completedCount = meetingSessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }.count
        let activeCount = meetingStartedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } == true ? 1 : 0
        return completedCount + activeCount
    }

    func meetingCount(in interval: DateInterval) -> Int {
        let completedCount = meetingSessions.filter { interval.contains($0.startedAt) }.count
        let activeCount = meetingStartedAt.map { interval.contains($0) } == true ? 1 : 0
        return completedCount + activeCount
    }

    func meetingDuration(on date: Date) -> TimeInterval {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return 0 }
        return meetingDuration(in: interval)
    }

    func meetingDuration(in interval: DateInterval) -> TimeInterval {
        duration(of: mergedIntervals(meetingIntervals(in: interval)))
    }

    func routineCount(on date: Date) -> Int {
        let completedCount = routineSessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }.count
        let activeCount = activeRoutineStartedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } == true ? 1 : 0
        return completedCount + activeCount
    }

    func routineCount(in interval: DateInterval) -> Int {
        let completedCount = routineSessions.filter { interval.contains($0.startedAt) }.count
        let activeCount = activeRoutineStartedAt.map { interval.contains($0) } == true ? 1 : 0
        return completedCount + activeCount
    }

    func routineDuration(on date: Date) -> TimeInterval {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return 0 }
        return routineDuration(in: interval)
    }

    func routineDuration(in interval: DateInterval?) -> TimeInterval {
        effectiveRoutineDuration(in: interval)
    }

    func productiveRoutineDuration(on date: Date) -> TimeInterval {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return 0 }
        return productiveRoutineDuration(in: interval)
    }

    func productiveRoutineDuration(in interval: DateInterval) -> TimeInterval {
        productiveRoutineDuration(in: Optional(interval))
    }

    func activeDuration(on date: Date) -> TimeInterval {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return 0 }
        return activeDuration(in: interval)
    }

    func activeDuration(in interval: DateInterval) -> TimeInterval {
        activeWorkDuration(in: interval)
    }

    func taskFocusDuration(in interval: DateInterval, finished: Bool) -> TimeInterval {
        let taskIDs = Set(tasks.filter { $0.finished == finished }.map(\.id))
        let completedFocusIntervals = taskFocusSessions
            .filter { taskIDs.contains($0.taskID) }
            .compactMap { clippedInterval(start: $0.startedAt, end: $0.endedAt, to: interval) }
        var focusIntervals = completedFocusIntervals
        if let activeFocusTaskID = focusSessionTracker.taskID,
           taskIDs.contains(activeFocusTaskID),
           let activeFocusStartedAt = focusSessionTracker.startedAt,
           let current = clippedInterval(
               start: activeFocusStartedAt,
               end: max(currentDate, activeFocusStartedAt),
               to: interval
           ) {
            focusIntervals.append(current)
        }

        let activeIntervals = activeWorkIntervals(in: interval)
        let activeFocusIntervals = mergedIntervals(focusIntervals).flatMap { focusInterval in
            activeIntervals.compactMap { activeInterval in
                clippedInterval(start: focusInterval.start, end: focusInterval.end, to: activeInterval)
            }
        }
        return duration(of: mergedIntervals(activeFocusIntervals))
    }

    func taskFocusCount(in interval: DateInterval, finished: Bool) -> Int {
        let taskIDs = Set(tasks.filter { $0.finished == finished }.map(\.id))
        let activeIntervals = activeWorkIntervals(in: interval)
        guard !activeIntervals.isEmpty else { return 0 }

        func overlapsTrackedWork(start: Date, end: Date) -> Bool {
            guard let focusInterval = clippedInterval(start: start, end: end, to: interval) else { return false }
            return activeIntervals.contains { activeInterval in
                focusInterval.start < activeInterval.end && focusInterval.end > activeInterval.start
            }
        }

        var focusedTaskIDs = Set(taskFocusSessions.compactMap { session -> UUID? in
            guard taskIDs.contains(session.taskID) else { return nil }
            return overlapsTrackedWork(start: session.startedAt, end: session.endedAt) ? session.taskID : nil
        })
        if let activeFocusTaskID = focusSessionTracker.taskID,
           taskIDs.contains(activeFocusTaskID),
           let activeFocusStartedAt = focusSessionTracker.startedAt,
           overlapsTrackedWork(
               start: activeFocusStartedAt,
               end: max(currentDate, activeFocusStartedAt)
           ) {
            focusedTaskIDs.insert(activeFocusTaskID)
        }
        return focusedTaskIDs.count
    }

    func firstActiveAt(on date: Date) -> Date? {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return nil }
        return activeWorkBounds(in: interval)?.start
    }

    func lastActiveAt(on date: Date) -> Date? {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return nil }
        return activeWorkBounds(in: interval)?.end
    }

    func productiveDuration(on date: Date) -> TimeInterval {
        activeDuration(on: date) + productiveRoutineDuration(on: date)
    }

    func productiveDuration(in interval: DateInterval) -> TimeInterval {
        activeDuration(in: interval) + productiveRoutineDuration(in: interval)
    }

    var completedTaskStats: [TaskCompletionStat] {
        completedTaskStats(on: nil)
    }

    func completedTaskStats(on date: Date?) -> [TaskCompletionStat] {
        finishedTasks.compactMap { task in
            guard
                let createdLoop = task.createdLoop,
                let finishedLoop = task.finishedLoop,
                let finishedAt = task.finishedAt
            else {
                return nil
            }
            if let date, !Calendar.current.isDate(finishedAt, inSameDayAs: date) {
                return nil
            }

            return TaskCompletionStat(
                id: task.id,
                title: task.title,
                loopsTaken: max(1, finishedLoop - createdLoop + 1),
                finishedAt: finishedAt
            )
        }
        .sorted { $0.finishedAt > $1.finishedAt }
    }

    func completedTaskStats(in interval: DateInterval) -> [TaskCompletionStat] {
        completedTaskStats(on: nil).filter { interval.contains($0.finishedAt) }
    }

    var averageLoopsToFinish: Double? {
        averageLoopsToFinish(on: nil)
    }

    func averageLoopsToFinish(on date: Date?) -> Double? {
        let stats = completedTaskStats(on: date)
        guard !stats.isEmpty else { return nil }
        let totalLoops = stats.reduce(0) { $0 + $1.loopsTaken }
        return Double(totalLoops) / Double(stats.count)
    }

    func averageLoopsToFinish(in interval: DateInterval) -> Double? {
        let stats = completedTaskStats(in: interval)
        guard !stats.isEmpty else { return nil }
        let totalLoops = stats.reduce(0) { $0 + $1.loopsTaken }
        return Double(totalLoops) / Double(stats.count)
    }

    var shouldSuggestAddingTaskToFastLoop: Bool {
        let taskCount = currentLoopTasks.count
        guard (2...3).contains(taskCount), loopCompletions.count >= 2 else { return false }

        let recentCompletions = loopCompletions.suffix(2)
        guard
            let previousCompletion = recentCompletions.first?.completedAt,
            let latestCompletion = recentCompletions.last?.completedAt
        else {
            return false
        }

        if let dismissedFastLoopSuggestionAt, dismissedFastLoopSuggestionAt >= latestCompletion {
            return false
        }

        let now = Date()
        return now.timeIntervalSince(latestCompletion) <= fastLoopSuggestionWindow
            && latestCompletion.timeIntervalSince(previousCompletion) <= fastLoopCompletionThreshold
    }

    var shouldShowMorningOnboarding: Bool {
        guard !isOnBreak, !isInMeeting, !isInRoutine else { return false }
        guard loopsCompletedToday == 0 else { return false }
        guard let morningOnboardingShownAt else { return true }
        return !Calendar.current.isDate(morningOnboardingShownAt, inSameDayAs: currentDate)
    }

    func suggestion(for task: LoopTask) -> LoopTaskSuggestion? {
        guard !task.isBacklog, !task.finished else { return nil }

        if shouldSuggestSnoozeAfterQuickCompletion(for: task) {
            return dismissedSuggestion(.snoozeAfterQuickDone, for: task) ? nil : .snoozeAfterQuickDone
        }

        if shouldSuggestMarkingPriority(for: task) {
            return dismissedSuggestion(.markPriority, for: task) ? nil : .markPriority
        }

        if shouldSuggestEditingCadence(for: task) {
            return dismissedSuggestion(.editCadence, for: task) ? nil : .editCadence
        }

        return nil
    }

    func dismissSuggestion(_ suggestion: LoopTaskSuggestion, for task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard !tasks[index].dismissedSuggestions.contains(suggestion) else { return }
        recordAction(.dismissSuggestion)
        tasks[index].dismissedSuggestions.append(suggestion)
        tasks[index].updatedAt = Date()
    }

    func dismissFastLoopSuggestion() {
        recordAction(.dismissFastLoopSuggestion)
        dismissedFastLoopSuggestionAt = Date()
    }

    func markMorningOnboardingShown() {
        recordAction(.completeMorningPlan)
        morningOnboardingShownAt = Date()
    }

    func refreshCurrentDate() {
        tickCurrentDate()
    }

    func addRoutineBlock(
        title: String,
        linkedApp: LinkedApp? = nil,
        cadence: LoopCadence = .everyTwoLoops,
        durationMinutes: Int = 5,
        countsAsProductive: Bool = true,
        isEnabled: Bool = true,
        scheduleTimes: [DailyScheduleTime] = []
    ) {
        let routine = RoutineBlock(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            linkedApp: linkedApp,
            cadence: cadence,
            durationMinutes: normalizedRoutineDurationMinutes(durationMinutes),
            countsAsProductive: countsAsProductive,
            isEnabled: isEnabled,
            scheduleTimes: normalizedScheduleTimes(scheduleTimes),
            sortOrder: nextRoutineSortOrder()
        )
        guard !routine.title.isEmpty else { return }
        recordAction(.addRoutine)
        routineBlocks.append(routine)
    }

    func updateRoutineBlock(_ routine: RoutineBlock) {
        guard let index = routineBlocks.firstIndex(where: { $0.id == routine.id }) else { return }
        let previousRoutine = routineBlocks[index]
        var updatedRoutine = routine
        updatedRoutine.title = updatedRoutine.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updatedRoutine.title.isEmpty else { return }
        updatedRoutine.durationMinutes = normalizedRoutineDurationMinutes(updatedRoutine.durationMinutes)
        updatedRoutine.scheduleTimes = normalizedScheduleTimes(updatedRoutine.scheduleTimes)
        if previousRoutine.cadence != updatedRoutine.cadence {
            updatedRoutine.lastCompletedLoop = nil
        }
        if previousRoutine.scheduleTimes != updatedRoutine.scheduleTimes {
            updatedRoutine.lastCompletedScheduledAt = nil
        }
        updatedRoutine.updatedAt = Date()
        recordAction(.updateRoutine)
        routineBlocks[index] = updatedRoutine

        if activeRoutineBlockID == updatedRoutine.id {
            activeRoutineUntil = (activeRoutineStartedAt ?? Date()).addingTimeInterval(TimeInterval(updatedRoutine.durationMinutes * 60))
            activeRoutineScheduledAt = activeScheduledDate(for: updatedRoutine)
        }
    }

    func updateRoutineCadence(_ routine: RoutineBlock, to cadence: LoopCadence) {
        guard let index = routineBlocks.firstIndex(where: { $0.id == routine.id }) else { return }
        guard routineBlocks[index].cadence != cadence else { return }

        routineBlocks[index].cadence = cadence
        routineBlocks[index].lastCompletedLoop = nil
        routineBlocks[index].updatedAt = Date()
        recordAction(.updateRoutine)
    }

    func setRoutineEnabled(_ routine: RoutineBlock, isEnabled: Bool) {
        guard let index = routineBlocks.firstIndex(where: { $0.id == routine.id }) else { return }
        guard routineBlocks[index].isEnabled != isEnabled else { return }

        if !isEnabled, activeRoutineBlockID == routine.id {
            endRoutineBlock(markComplete: false)
        }

        guard let updatedIndex = routineBlocks.firstIndex(where: { $0.id == routine.id }) else { return }
        routineBlocks[updatedIndex].isEnabled = isEnabled
        routineBlocks[updatedIndex].updatedAt = Date()
        recordAction(.updateRoutine)
    }

    func deleteRoutineBlock(_ routine: RoutineBlock) {
        guard routineBlocks.contains(where: { $0.id == routine.id }) else { return }
        if activeRoutineBlockID == routine.id {
            endRoutineBlock(markComplete: false)
        }
        recordAction(.deleteRoutine)
        routineBlocks.removeAll { $0.id == routine.id }
    }

    func startRoutineBlock(_ routine: RoutineBlock) {
        guard isInteractiveTrackingEnabled else { return }
        guard !isOnBreak, !isInMeeting else { return }
        if isInRoutine {
            endRoutineBlock(markComplete: false)
        }
        guard let storedRoutine = routineBlocks.first(where: { $0.id == routine.id && $0.isEnabled }) else { return }
        recordAction(.startRoutine)
        let now = Date()
        activeRoutineBlockID = storedRoutine.id
        activeRoutineStartedAt = now
        activeRoutineUntil = now.addingTimeInterval(TimeInterval(normalizedRoutineDurationMinutes(storedRoutine.durationMinutes) * 60))
        activeRoutineScheduledAt = activeScheduledDate(for: storedRoutine, at: now)
        clearFocusedTask(at: now)
        lastAutoOpenedFocusedTaskID = nil
        currentDate = now
        postFocusStarted(.routine(storedRoutine.id))
        openLinkedApp(for: storedRoutine)
    }

    func endRoutineBlock(markComplete: Bool = true) {
        let now = Date()
        guard
            let activeRoutineBlockID,
            let activeRoutineStartedAt
        else {
            return
        }

        recordAction(markComplete ? .completeRoutine : .skipRoutine)
        let routine = routineBlocks.first { $0.id == activeRoutineBlockID }
        let routineEndedAt = boundedRoutineEnd(startedAt: activeRoutineStartedAt, requestedEnd: now)
        pauseIterationTimers(by: routineEndedAt.timeIntervalSince(activeRoutineStartedAt))
        if isValidRoutineSession(startedAt: activeRoutineStartedAt, endedAt: routineEndedAt) {
            routineSessions.append(RoutineSession(
                routineBlockID: activeRoutineBlockID,
                title: routine?.title ?? "Routine",
                countsAsProductive: routine?.countsAsProductive ?? true,
                startedAt: activeRoutineStartedAt,
                endedAt: routineEndedAt
            ))
        }

        if markComplete, let index = routineBlocks.firstIndex(where: { $0.id == activeRoutineBlockID }) {
            if let activeRoutineScheduledAt {
                routineBlocks[index].lastCompletedScheduledAt = activeRoutineScheduledAt
            } else {
                routineBlocks[index].lastCompletedLoop = loopNumber
            }
            routineBlocks[index].updatedAt = now
        }

        self.activeRoutineBlockID = nil
        self.activeRoutineStartedAt = nil
        self.activeRoutineUntil = nil
        self.activeRoutineScheduledAt = nil
        currentDate = now
        if markComplete, advanceLoopIfNoUndoneCurrentLoopTasks(openNextFocusedApp: true) {
            postFocusModeEnded(.routine)
            return
        }
        ensureFocusedTask(openLinkedAppIfChanged: true)
        postFocusModeEnded(.routine)
    }

    private func pauseIterationTimers(by duration: TimeInterval) {
        guard duration > 0 else { return }
        for index in tasks.indices {
            guard let startedAt = tasks[index].iterationTimerStartedAt else { continue }
            tasks[index].iterationTimerStartedAt = startedAt.addingTimeInterval(duration)
        }
    }

    func reopenRoutineBlock(_ routine: RoutineBlock) {
        guard let index = routineBlocks.firstIndex(where: { $0.id == routine.id }) else { return }
        recordAction(.reopenRoutine)
        let now = Date()
        if routineBlocks[index].lastCompletedLoop == loopNumber {
            routineBlocks[index].lastCompletedLoop = nil
        }
        if let lastCompletedScheduledAt = routineBlocks[index].lastCompletedScheduledAt,
           Calendar.current.isDate(lastCompletedScheduledAt, inSameDayAs: currentDate) {
            routineBlocks[index].lastCompletedScheduledAt = nil
        }
        routineBlocks[index].updatedAt = now
        currentDate = now
        ensureFocusedTask(openLinkedAppIfChanged: true)
    }

    func addTask(
        title: String,
        linkedApp: LinkedApp? = nil,
        cadence: LoopCadence = .everyLoop,
        iterationTimerMinutes: Int? = nil,
        scheduledFor: Date? = nil,
        addToIteration: Bool = true,
        addToCurrentIteration: Bool? = nil
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let startsInCurrentIteration = addToCurrentIteration ?? newTasksStartInCurrentIteration
        let targetLoop = addToIteration ? (startsInCurrentIteration ? loopNumber : loopNumber + 1) : nil
        recordAction(addToIteration ? .addTask : .addBacklogTask)
        tasks.append(LoopTask(
            title: trimmedTitle,
            linkedApp: linkedApp,
            cadence: cadence,
            isBacklog: !addToIteration,
            sortOrder: nextSortOrder(),
            createdLoop: targetLoop,
            iterationTimerMinutes: normalizedIterationTimerMinutes(iterationTimerMinutes) ?? defaultIterationTimerMinutesOrNil,
            scheduledFor: scheduledFor
        ))
        ensureFocusedTask()
    }

    func setNewTasksStartInCurrentIteration(_ startsInCurrentIteration: Bool) {
        newTasksStartInCurrentIteration = startsInCurrentIteration
    }

    func updateTask(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let previousTask = tasks[index]
        let wasUndoneCurrentLoopTask = currentLoopTasks.contains { $0.id == task.id && !$0.doneThisLoop }
        var updatedTask = task
        updatedTask.title = updatedTask.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updatedTask.title.isEmpty else { return }
        updatedTask.createdLoop = updatedTask.createdLoop ?? previousTask.createdLoop ?? loopNumber
        if previousTask.cadence != updatedTask.cadence {
            updatedTask.snoozeCount = 0
        }

        if updatedTask.isBacklog {
            updatedTask.doneThisLoop = false
            updatedTask.lastCompletedLoop = nil
            updatedTask.snoozedUntil = nil
            updatedTask.lastQuickCompletionAt = nil
            updatedTask.iterationTimerStartedAt = nil
            updatedTask.iterationTimerStartedLoop = nil
            updatedTask.finished = false
        }

        if updatedTask.finished {
            updatedTask.isBacklog = false
            updatedTask.doneThisLoop = true
            updatedTask.lastCompletedLoop = loopNumber
            updatedTask.finishedLoop = updatedTask.finishedLoop ?? loopNumber
            updatedTask.finishedAt = updatedTask.finishedAt ?? Date()
            updatedTask.snoozedUntil = nil
            updatedTask.lastQuickCompletionAt = nil
            updatedTask.iterationTimerStartedAt = nil
            updatedTask.iterationTimerStartedLoop = nil
        } else if previousTask.finished {
            updatedTask.finishedLoop = nil
            updatedTask.finishedAt = nil
        }

        if updatedTask.isPriority && !updatedTask.finished {
            updatedTask.doneThisLoop = false
            updatedTask.lastCompletedLoop = nil
            updatedTask.lastQuickCompletionAt = nil
            if !previousTask.isPriority {
                updatedTask.priorityDeferredLoop = nil
            }
        }

        updatedTask.iterationTimerMinutes = normalizedIterationTimerMinutes(updatedTask.iterationTimerMinutes)
        if updatedTask.iterationTimerMinutes == nil || previousTask.iterationTimerMinutes != updatedTask.iterationTimerMinutes {
            updatedTask.iterationTimerStartedAt = nil
            updatedTask.iterationTimerStartedLoop = nil
        }

        if updatedTask.doneThisLoop {
            updatedTask.lastCompletedLoop = loopNumber
            updatedTask.iterationTimerStartedAt = nil
            updatedTask.iterationTimerStartedLoop = nil
            if !previousTask.doneThisLoop {
                recordQuickCompletionIfNeeded(for: &updatedTask)
            }
            if !updatedTask.isPriority {
                clearPriorityDeferrals()
            }
        } else if updatedTask.lastCompletedLoop == loopNumber {
            updatedTask.lastCompletedLoop = nil
            updatedTask.lastQuickCompletionAt = nil
        }
        updatedTask.updatedAt = Date()
        recordAction(.updateTask)
        tasks[index] = updatedTask
        if !previousTask.doneThisLoop && updatedTask.doneThisLoop && !updatedTask.finished {
            if !focusPriorityAfterRegularTaskCompletion(openNextFocusedApp: true),
               !advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: true) {
                ensureFocusedTask(openLinkedAppIfChanged: true)
            }
        } else if wasUndoneCurrentLoopTask && !previousTask.finished && updatedTask.finished {
            if !advanceLoopIfNoUndoneCurrentLoopTasks(openNextFocusedApp: true) {
                ensureFocusedTask(openLinkedAppIfChanged: true)
            }
        } else {
            ensureFocusedTask()
        }
    }

    func updateTaskTitle(_ task: LoopTask, title: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        guard tasks[index].title != trimmedTitle else { return }
        recordAction(.renameTask)
        tasks[index].title = trimmedTitle
        tasks[index].updatedAt = Date()
    }

    func toggleDone(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard !tasks[index].isBacklog else { return }
        if tasks[index].isPriority && !tasks[index].doneThisLoop {
            recordAction(.completeTask)
            completePriorityTask(at: index, openNextFocusedApp: true)
            return
        }
        let action: LoopAction = tasks[index].doneThisLoop ? .reopenTask : .completeTask
        recordAction(action)
        tasks[index].doneThisLoop.toggle()
        if tasks[index].doneThisLoop {
            tasks[index].lastCompletedLoop = loopNumber
            tasks[index].snoozedUntil = nil
            tasks[index].iterationTimerStartedAt = nil
            tasks[index].iterationTimerStartedLoop = nil
            recordQuickCompletionIfNeeded(for: &tasks[index])
            clearPriorityDeferrals()
        } else if tasks[index].lastCompletedLoop == loopNumber {
            tasks[index].lastCompletedLoop = nil
            tasks[index].lastQuickCompletionAt = nil
        }
        tasks[index].updatedAt = Date()
        if tasks[index].doneThisLoop {
            if !focusPriorityAfterRegularTaskCompletion(openNextFocusedApp: true),
               !advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: true) {
                ensureFocusedTask(openLinkedAppIfChanged: true)
            }
        } else {
            ensureFocusedTask()
        }
    }

    @discardableResult
    func markFocusedTaskDone(openNextFocusedApp: Bool) -> Bool {
        guard
            let currentFocusTaskID,
            let task = tasks.first(where: { $0.id == currentFocusTaskID && !$0.doneThisLoop })
        else {
            return false
        }

        recordAction(.completeFocusedTask)
        return markTaskDone(task, openNextFocusedApp: openNextFocusedApp)
    }

    func finish(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        recordAction(.finishTask)
        let wasUndoneCurrentLoopTask = currentLoopTasks.contains { $0.id == task.id && !$0.doneThisLoop }
        tasks[index].finished = true
        tasks[index].isBacklog = false
        tasks[index].doneThisLoop = true
        tasks[index].lastCompletedLoop = loopNumber
        tasks[index].createdLoop = tasks[index].createdLoop ?? loopNumber
        tasks[index].finishedLoop = loopNumber
        tasks[index].finishedAt = Date()
        tasks[index].snoozedUntil = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = Date()
        if wasUndoneCurrentLoopTask && advanceLoopIfNoUndoneCurrentLoopTasks(openNextFocusedApp: true) {
            return
        }
        ensureFocusedTask()
    }

    func restore(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        recordAction(.restoreTask)
        tasks[index].finished = false
        tasks[index].doneThisLoop = false
        tasks[index].lastCompletedLoop = nil
        tasks[index].finishedLoop = nil
        tasks[index].finishedAt = nil
        tasks[index].snoozedUntil = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = Date()
        ensureFocusedTask()
    }

    func delete(_ task: LoopTask) {
        guard tasks.contains(where: { $0.id == task.id }) else { return }
        recordAction(.deleteTask)
        clearFocusedTask(ifMatching: task.id)
        tasks.removeAll { $0.id == task.id }
        ensureFocusedTask()
    }

    func addToIteration(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return }
        recordAction(.addToIteration)
        tasks[index].isBacklog = false
        tasks[index].doneThisLoop = false
        tasks[index].lastCompletedLoop = nil
        tasks[index].snoozedUntil = nil
        tasks[index].scheduledFor = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].createdLoop = tasks[index].createdLoop ?? loopNumber
        tasks[index].sortOrder = nextSortOrder()
        tasks[index].updatedAt = Date()
        ensureFocusedTask(openLinkedAppIfChanged: false)
    }

    func moveToBacklog(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return }
        recordAction(.moveToBacklog)
        let wasUndoneCurrentLoopTask = currentLoopTasks.contains { $0.id == task.id && !$0.doneThisLoop }
        tasks[index].isBacklog = true
        tasks[index].doneThisLoop = false
        tasks[index].lastCompletedLoop = nil
        tasks[index].snoozedUntil = nil
        tasks[index].scheduledFor = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = Date()
        clearFocusedTask(ifMatching: task.id)
        if wasUndoneCurrentLoopTask && advanceLoopIfNoUndoneCurrentLoopTasks(openNextFocusedApp: true) {
            return
        }
        ensureFocusedTask()
    }

    func togglePriority(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        recordAction(tasks[index].isPriority ? .removePriority : .markPriority)
        tasks[index].isPriority.toggle()
        tasks[index].manualFocusCount = 0
        tasks[index].updatedAt = Date()
        if !tasks[index].isPriority {
            tasks[index].priorityDeferredLoop = nil
        } else {
            clearCurrentIterationPriority(except: task.id)
        }
        ensureFocusedTask()
    }

    func focus(_ task: LoopTask) {
        guard isInteractiveTrackingEnabled, !isOnBreak, !isInMeeting, !isInRoutine else { return }
        guard !task.isBacklog else { return }
        guard currentLoopTasks.contains(where: { $0.id == task.id && !$0.doneThisLoop }) else { return }
        recordAction(.focusTask)
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].manualFocusCount += 1
        }
        setFocusedTaskID(task.id, openLinkedAppIfChanged: true)
    }

    func snooze(_ task: LoopTask, minutes: Int = 30) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return }
        guard !tasks[index].isBacklog else { return }
        recordAction(.snoozeTask)
        let wasDoneThisLoop = tasks[index].doneThisLoop
        tasks[index].snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        tasks[index].snoozeCount += 1
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = Date()
        clearFocusedTask(ifMatching: task.id)
        if wasDoneThisLoop {
            ensureFocusedTask()
            return
        }
        if !advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: true) {
            ensureFocusedTask(openLinkedAppIfChanged: true)
        }
    }

    func unsnooze(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        recordAction(.unsnoozeTask)
        tasks[index].snoozedUntil = nil
        tasks[index].updatedAt = Date()
        ensureFocusedTask()
    }

    func clearSchedule(for task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        recordAction(.clearSchedule)
        tasks[index].scheduledFor = nil
        tasks[index].updatedAt = Date()
        ensureFocusedTask()
    }

    func scheduleForNextWorkingDay(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return }
        guard !tasks[index].isBacklog else { return }

        recordAction(.scheduleForNextWorkingDay)
        let now = Date()
        tasks[index].scheduledFor = nextWorkingDay(atHour: 7, from: now)
        tasks[index].snoozedUntil = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = now
        clearFocusedTask(ifMatching: task.id, at: now)
        ensureFocusedTask(openLinkedAppIfChanged: true)
    }

    func setAutoOpenFocusedTaskApp(_ isEnabled: Bool) {
        guard autoOpenFocusedTaskApp != isEnabled else { return }
        recordAction(.setAutoOpenFocusedTaskApp)
        autoOpenFocusedTaskApp = isEnabled
    }

    func setOpenLoopAtLogin(_ isEnabled: Bool) {
        recordAction(.setOpenLoopAtLogin)
        do {
            try LoginLaunchAgent.setEnabled(isEnabled)
            openLoopAtLogin = LoginLaunchAgent.isEnabled
        } catch {
            openLoopAtLogin = LoginLaunchAgent.isEnabled
            notice = "Could not update login launch setting."
        }
    }

    func setBreakDurationMinutes(_ minutes: Int) {
        let clampedMinutes = min(max(minutes, 1), 120)
        guard breakDurationMinutes != clampedMinutes else { return }
        recordAction(.setBreakDuration)
        breakDurationMinutes = clampedMinutes
        if isOnBreak, let breakStartedAt {
            breakUntil = breakStartedAt.addingTimeInterval(TimeInterval(clampedMinutes * 60))
        }
    }

    func setDefaultIterationTimerMinutes(_ minutes: Int) {
        let clampedMinutes = min(max(minutes, 0), 240)
        guard defaultIterationTimerMinutes != clampedMinutes else { return }
        recordAction(.setDefaultIterationTimer)
        defaultIterationTimerMinutes = clampedMinutes
    }

    func extendIterationTimer(for task: LoopTask, by minutes: Int) {
        guard minutes > 0 else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard
            !tasks[index].doneThisLoop,
            !tasks[index].finished,
            !tasks[index].isBacklog,
            normalizedIterationTimerMinutes(tasks[index].iterationTimerMinutes) != nil
        else {
            return
        }

        recordAction(.extendTimer)
        startIterationTimerIfNeeded(for: tasks[index].id)
        guard let startedAt = tasks[index].iterationTimerStartedAt else { return }
        tasks[index].iterationTimerStartedAt = startedAt.addingTimeInterval(TimeInterval(minutes * 60))
        tasks[index].updatedAt = Date()
        currentDate = Date()
    }

    func moveCurrentLoopTask(draggedTaskID: UUID, to targetTaskID: UUID) {
        guard draggedTaskID != targetTaskID else { return }

        var reorderedLoopTasks = currentLoopTasks
        guard
            let sourceIndex = reorderedLoopTasks.firstIndex(where: { $0.id == draggedTaskID }),
            let targetIndex = reorderedLoopTasks.firstIndex(where: { $0.id == targetTaskID })
        else {
            return
        }

        let movedTask = reorderedLoopTasks.remove(at: sourceIndex)
        let insertionIndex = min(targetIndex, reorderedLoopTasks.count)
        reorderedLoopTasks.insert(movedTask, at: insertionIndex)
        recordAction(.reorderTask)
        applyCurrentLoopTaskOrder(reorderedLoopTasks)
    }

    func moveCurrentLoopTask(_ task: LoopTask, by offset: Int) {
        guard offset != 0 else { return }
        var reorderedLoopTasks = currentLoopTasks.filter { !$0.doneThisLoop }
        guard let sourceIndex = reorderedLoopTasks.firstIndex(where: { $0.id == task.id }) else { return }
        let targetIndex = min(max(sourceIndex + offset, 0), reorderedLoopTasks.count - 1)
        guard sourceIndex != targetIndex else { return }
        let movedTask = reorderedLoopTasks.remove(at: sourceIndex)
        reorderedLoopTasks.insert(movedTask, at: targetIndex)
        recordAction(.reorderTask)
        applyCurrentLoopTaskOrder(reorderedLoopTasks)
    }

    func advanceLoop() {
        advanceLoop(openNextFocusedApp: false, resetFocusToFirstTask: true)
    }

    private func advanceLoop(openNextFocusedApp: Bool, resetFocusToFirstTask: Bool) {
        recordAction(.advanceLoop)
        loopCompletions.append(LoopCompletion(loopNumber: loopNumber))
        loopNumber += 1
        clearPriorityDeferrals()
        for index in tasks.indices where !tasks[index].isBacklog && !tasks[index].finished && tasks[index].doneThisLoop {
            tasks[index].doneThisLoop = false
            tasks[index].lastQuickCompletionAt = nil
            tasks[index].updatedAt = Date()
        }
        if resetFocusToFirstTask {
            clearFocusedTask()
        }
        ensureFocusedTask(openLinkedAppIfChanged: openNextFocusedApp)
    }

    private func advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: Bool) -> Bool {
        let currentTasks = currentLoopTasks.filter { !$0.isPriority }
        guard !currentTasks.isEmpty || !dueRoutineBlocks.isEmpty else { return false }
        guard currentTasks.allSatisfy(\.doneThisLoop) else { return false }
        if startNextDueRoutineIfReady() {
            return true
        }
        advanceLoop(openNextFocusedApp: openNextFocusedApp, resetFocusToFirstTask: true)
        return true
    }

    private func advanceLoopIfNoUndoneCurrentLoopTasks(openNextFocusedApp: Bool) -> Bool {
        guard !currentLoopTasks.contains(where: { !$0.isPriority && !$0.doneThisLoop }) else { return false }
        if startNextDueRoutineIfReady() {
            return true
        }
        advanceLoop(openNextFocusedApp: openNextFocusedApp, resetFocusToFirstTask: true)
        return true
    }

    func resetCurrentLoop() {
        recordAction(.resetLoop)
        for index in tasks.indices where !tasks[index].isBacklog && !tasks[index].finished {
            if tasks[index].lastCompletedLoop == loopNumber {
                tasks[index].lastCompletedLoop = nil
            }
            tasks[index].doneThisLoop = false
            tasks[index].lastQuickCompletionAt = nil
            tasks[index].iterationTimerStartedAt = nil
            tasks[index].iterationTimerStartedLoop = nil
            tasks[index].updatedAt = Date()
        }
        ensureFocusedTask()
    }

    func isDue(_ task: LoopTask) -> Bool {
        guard !task.isBacklog else { return false }
        guard !task.finished else { return false }
        guard !isSnoozed(task) else { return false }
        if let createdLoop = task.createdLoop, createdLoop > loopNumber {
            return false
        }
        if let scheduledFor = task.scheduledFor, scheduledFor > currentDate {
            return false
        }
        guard let lastCompletedLoop = task.lastCompletedLoop else { return true }
        return loopNumber - lastCompletedLoop >= task.cadence.rawValue
    }

    func isSnoozed(_ task: LoopTask, at date: Date = Date()) -> Bool {
        guard let snoozedUntil = task.snoozedUntil else { return false }
        return snoozedUntil > date
    }

    func isRoutineDue(_ routine: RoutineBlock) -> Bool {
        guard routine.isEnabled else { return false }
        guard activeRoutineBlockID != routine.id else { return false }
        if let scheduledDate = activeScheduledDate(for: routine) {
            return routine.lastCompletedScheduledAt.map { $0 < scheduledDate } ?? true
        }
        guard routine.scheduleTimes.isEmpty else { return false }
        guard let lastCompletedLoop = routine.lastCompletedLoop else { return true }
        return loopNumber - lastCompletedLoop >= routine.cadence.rawValue
    }

    func iterationTimerRemainingSeconds(for task: LoopTask, at date: Date? = nil) -> Int? {
        guard let timerMinutes = normalizedIterationTimerMinutes(task.iterationTimerMinutes) else { return nil }
        guard
            task.iterationTimerStartedLoop == loopNumber,
            let startedAt = task.iterationTimerStartedAt
        else {
            return timerMinutes * 60
        }

        let deadline = startedAt.addingTimeInterval(TimeInterval(timerMinutes * 60))
        return Int(ceil(deadline.timeIntervalSince(date ?? currentDate)))
    }

    static func timerText(forRemainingSeconds remainingSeconds: Int) -> String {
        if remainingSeconds < 0 {
            let overdueMinutes = abs(remainingSeconds) / 60
            guard overdueMinutes > 0 else { return "0m" }
            return "-\(overdueMinutes)m"
        }

        let remainingMinutes = max(0, Int(ceil(Double(remainingSeconds) / 60.0)))
        return "\(remainingMinutes)m"
    }

    func nextDueLoop(for task: LoopTask) -> Int? {
        guard let lastCompletedLoop = task.lastCompletedLoop else { return nil }
        return lastCompletedLoop + task.cadence.rawValue
    }

    func applyShortcut(_ newShortcut: KeyboardShortcutSetting) {
        let normalizedShortcut = newShortcut.normalized
        guard normalizedShortcut.isValid else {
            notice = "Choose a shortcut with at least one modifier and a key."
            return
        }

        shortcut = normalizedShortcut
        save()
        onShortcutChange?(normalizedShortcut)
    }

    func applyDoneShortcut(_ newShortcut: KeyboardShortcutSetting) {
        let normalizedShortcut = newShortcut.normalized
        guard normalizedShortcut.isValid else {
            notice = "Choose a shortcut with at least one modifier and a key."
            return
        }

        doneShortcut = normalizedShortcut
        save()
        onDoneShortcutChange?(normalizedShortcut)
    }

    func applyQuickAddShortcut(_ newShortcut: KeyboardShortcutSetting) {
        let normalizedShortcut = newShortcut.normalized
        guard normalizedShortcut.isValid else {
            notice = "Choose a shortcut with at least one modifier and a key."
            return
        }

        quickAddShortcut = normalizedShortcut
        save()
        onQuickAddShortcutChange?(normalizedShortcut)
    }

    func applyBreakShortcut(_ newShortcut: KeyboardShortcutSetting) {
        let normalizedShortcut = newShortcut.normalized
        guard normalizedShortcut.isValid else {
            notice = "Choose a shortcut with at least one modifier and a key."
            return
        }

        breakShortcut = normalizedShortcut
        save()
        onBreakShortcutChange?(normalizedShortcut)
    }

    func startBreak() {
        guard isInteractiveTrackingEnabled else { return }
        guard !isOnBreak else {
            endBreak()
            return
        }
        guard !isInMeeting, !isInRoutine else { return }

        let now = Date()
        recordAction(.startBreak)
        breakShouldFocusPriorityAfterBreak = false
        closeTaskFocusSession(at: now)
        breakStartedAt = now
        breakUntil = now.addingTimeInterval(breakDurationSeconds)
        currentDate = now
        postFocusStarted(.break)
    }

    func endBreak() {
        let now = Date()
        guard breakStartedAt != nil else { return }
        recordAction(.endBreak)
        if let breakStartedAt {
            let endedAt = max(now, breakStartedAt)
            if endedAt > breakStartedAt {
                breakSessions.append(BreakSession(startedAt: breakStartedAt, endedAt: endedAt))
                pauseIterationTimers(by: endedAt.timeIntervalSince(breakStartedAt))
            }
        }
        breakStartedAt = nil
        breakUntil = nil
        currentDate = now
        resumeAfterBreak()
        postFocusModeEnded(.break)
    }

    func setMeetingActive(_ isActive: Bool) {
        let now = Date()
        currentDate = now

        if isActive {
            guard isInteractiveTrackingEnabled else { return }
            guard meetingStartedAt == nil else { return }
            if isOnBreak {
                endBreakForSleep(at: now)
                postFocusModeEnded(.break)
            }
            if isInRoutine {
                endRoutineForSleep(at: now)
                postFocusModeEnded(.routine)
            }
            recordAction(.startMeeting)
            clearFocusedTask(at: now)
            meetingStartedAt = now
            lastAutoOpenedFocusedTaskID = nil
            return
        }

        guard let meetingStartedAt else { return }
        recordAction(.endMeeting)
        let endedAt = max(now, meetingStartedAt)
        if endedAt > meetingStartedAt {
            meetingSessions.append(MeetingSession(startedAt: meetingStartedAt, endedAt: endedAt))
            pauseIterationTimers(by: endedAt.timeIntervalSince(meetingStartedAt))
        }
        self.meetingStartedAt = nil
        ensureFocusedTask(openLinkedAppIfChanged: true)
        postFocusModeEnded(.meeting)
    }

    func endMeetingManually() {
        setMeetingActive(false)
    }

    func resumeInteractiveTracking(at now: Date = Date()) {
        guard !isInteractiveTrackingEnabled else { return }
        resumePausedTimers(at: now)
        currentDate = now
        lastTrackingTickDate = now
        lastAwakeUptime = ProcessInfo.processInfo.systemUptime
        isInteractiveTrackingEnabled = true
        trackingHeartbeatAt = now
        if activeStartedAt == nil {
            activeStartedAt = now
        }
        if !isOnBreak, !isInMeeting, !isInRoutine {
            ensureFocusedTask()
            if let focusedTaskID {
                recordFocusStarted(for: focusedTaskID, at: now)
            }
        }
        saveNow()
    }

    func suspendTracking(at now: Date = Date()) {
        guard isInteractiveTrackingEnabled else { return }
        isInteractiveTrackingEnabled = false
        currentDate = now
        lastTrackingTickDate = now
        closeTaskFocusSession(at: now)
        endActiveSession(at: now)
        endBreakForSleep(at: now)
        endMeetingForSleep(at: now)
        endRoutineForSleep(at: now)
        if sleepStartedAt == nil {
            sleepStartedAt = now
        }
        lastAwakeUptime = ProcessInfo.processInfo.systemUptime
    }

    func noteSystemWake(at now: Date = Date()) {
        detectSuspensionIfNeeded(at: now, awakeUptime: ProcessInfo.processInfo.systemUptime)
        currentDate = now
    }

    private func resumePausedTimers(at now: Date) {
        guard let sleepStartedAt else { return }
        let sleepDuration = now.timeIntervalSince(sleepStartedAt)
        guard sleepDuration > 0 else {
            self.sleepStartedAt = nil
            return
        }

        for index in tasks.indices {
            guard let timerStart = tasks[index].iterationTimerStartedAt else { continue }
            tasks[index].iterationTimerStartedAt = TimeTracking.resumedTimerStart(
                timerStart,
                suspendedAt: sleepStartedAt,
                resumedAt: now
            )
        }
        self.sleepStartedAt = nil
    }

    private func endActiveSession(at now: Date) {
        currentDate = now
        guard let activeStartedAt else { return }
        let endedAt = max(now, activeStartedAt)
        if endedAt > activeStartedAt {
            activeSessions.append(ActiveSession(startedAt: activeStartedAt, endedAt: endedAt))
        }
        self.activeStartedAt = nil
    }

    private func endBreakForSleep(at now: Date) {
        guard let breakStartedAt else { return }
        let endedAt = max(now, breakStartedAt)
        if endedAt > breakStartedAt {
            breakSessions.append(BreakSession(startedAt: breakStartedAt, endedAt: endedAt))
            pauseIterationTimers(by: endedAt.timeIntervalSince(breakStartedAt))
        }
        self.breakStartedAt = nil
        breakUntil = nil
        breakShouldFocusPriorityAfterBreak = false
    }

    private func closeTaskFocusSession(at now: Date) {
        let trackedTaskID = focusSessionTracker.taskID
        let closedSession = focusSessionTracker.close(at: now)
        if let trackedTaskID,
           let index = tasks.firstIndex(where: { $0.id == trackedTaskID }) {
            tasks[index].focusedAt = nil
        }
        guard let closedSession else { return }
        taskFocusSessions.append(TaskFocusSession(
            taskID: closedSession.taskID,
            startedAt: closedSession.interval.start,
            endedAt: closedSession.interval.end
        ))
    }

    private func clearFocusedTask(at now: Date = Date()) {
        closeTaskFocusSession(at: now)
        if focusedTaskID != nil {
            focusedTaskID = nil
        }
    }

    private func clearFocusedTask(ifMatching taskID: UUID, at now: Date = Date()) {
        guard focusedTaskID == taskID else { return }
        clearFocusedTask(at: now)
    }

    private func endMeetingForSleep(at now: Date) {
        guard let meetingStartedAt else { return }
        let endedAt = max(now, meetingStartedAt)
        if endedAt > meetingStartedAt {
            meetingSessions.append(MeetingSession(startedAt: meetingStartedAt, endedAt: endedAt))
            pauseIterationTimers(by: endedAt.timeIntervalSince(meetingStartedAt))
        }
        self.meetingStartedAt = nil
    }

    private func endRoutineForSleep(at now: Date) {
        guard
            let activeRoutineBlockID,
            let activeRoutineStartedAt
        else {
            return
        }

        let endedAt = boundedRoutineEnd(startedAt: activeRoutineStartedAt, requestedEnd: now)
        let routine = routineBlocks.first { $0.id == activeRoutineBlockID }
        pauseIterationTimers(by: endedAt.timeIntervalSince(activeRoutineStartedAt))
        if isValidRoutineSession(startedAt: activeRoutineStartedAt, endedAt: endedAt) {
            routineSessions.append(RoutineSession(
                routineBlockID: activeRoutineBlockID,
                title: routine?.title ?? "Routine",
                countsAsProductive: routine?.countsAsProductive ?? true,
                startedAt: activeRoutineStartedAt,
                endedAt: endedAt
            ))
        }

        self.activeRoutineBlockID = nil
        self.activeRoutineStartedAt = nil
        activeRoutineUntil = nil
        activeRoutineScheduledAt = nil
    }

    func openLinkedApp(for task: LoopTask) {
        guard let linkedApp = task.linkedApp else {
            notice = "No app selected for \(task.title)."
            return
        }

        guard let appURL = applicationURL(for: linkedApp) else {
            notice = "Could not find \(linkedApp.name)."
            return
        }

        guard !openingTaskIDs.contains(task.id) else { return }
        openingTaskIDs.insert(task.id)
        NotificationCenter.default.post(name: .loopShouldClosePopover, object: nil)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] runningApplication, error in
            Task { @MainActor in
                self?.openingTaskIDs.remove(task.id)
                if error != nil {
                    self?.lastAutoOpenedFocusedTaskID = nil
                    self?.notice = "Could not open \(linkedApp.name)."
                    return
                }

                self?.activateLinkedApp(linkedApp, runningApplication: runningApplication)
            }
        }
    }

    func openLinkedApp(for routine: RoutineBlock) {
        guard let linkedApp = routine.linkedApp else { return }

        guard let appURL = applicationURL(for: linkedApp) else {
            notice = "Could not find \(linkedApp.name)."
            return
        }

        NotificationCenter.default.post(name: .loopShouldClosePopover, object: nil)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] runningApplication, error in
            Task { @MainActor in
                if error != nil {
                    self?.notice = "Could not open \(linkedApp.name)."
                    return
                }

                self?.activateLinkedApp(linkedApp, runningApplication: runningApplication)
            }
        }
    }

    private func activateLinkedApp(_ linkedApp: LinkedApp, runningApplication: NSRunningApplication?) {
        if isSafari(linkedApp) {
            activateSafari()
            return
        }

        let activationOptions: NSApplication.ActivationOptions = [.activateAllWindows, .activateIgnoringOtherApps]
        if runningApplication?.activate(options: activationOptions) == true {
            return
        }

        if let bundleIdentifier = linkedApp.bundleIdentifier,
           NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleIdentifier == bundleIdentifier })?
               .activate(options: activationOptions) == true {
            return
        }

        activateLinkedAppWithAppleScript(linkedApp)
    }

    private func activateSafari() {
        _ = openBundleIdentifier("com.apple.Safari")
        activateRunningApplication(bundleIdentifier: "com.apple.Safari")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.activateRunningApplication(bundleIdentifier: "com.apple.Safari")
            self?.activateSafariWithAppleScript()
        }
    }

    private func activateRunningApplication(bundleIdentifier: String) {
        let activationOptions: NSApplication.ActivationOptions = [.activateAllWindows, .activateIgnoringOtherApps]
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })?
            .activate(options: activationOptions)
    }

    private func activateLinkedAppWithAppleScript(_ linkedApp: LinkedApp) {
        let scriptSource: String
        if let bundleIdentifier = linkedApp.bundleIdentifier {
            scriptSource = "tell application id \"\(bundleIdentifier)\" to activate"
        } else {
            scriptSource = "tell application \"\(linkedApp.name)\" to activate"
        }

        var error: NSDictionary?
        NSAppleScript(source: scriptSource)?.executeAndReturnError(&error)
        if error != nil {
            notice = "Could not focus \(linkedApp.name)."
        }
    }

    private func activateSafariWithAppleScript() {
        let scriptSource = """
        tell application id "com.apple.Safari"
            activate
            if not (exists window 1) then make new document
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: scriptSource)?.executeAndReturnError(&error)
        if error != nil {
            notice = "Could not focus Safari."
        }
    }

    private func openBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isSafari(_ linkedApp: LinkedApp) -> Bool {
        linkedApp.bundleIdentifier == "com.apple.Safari"
            || linkedApp.name.localizedCaseInsensitiveCompare("Safari") == .orderedSame
    }

    private func applicationURL(for linkedApp: LinkedApp) -> URL? {
        if let path = linkedApp.path {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let bundleIdentifier = linkedApp.bundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }

        return nil
    }

    private func shouldSuggestSnoozeAfterQuickCompletion(for task: LoopTask) -> Bool {
        guard
            task.doneThisLoop,
            !isSnoozed(task),
            let lastQuickCompletionAt = task.lastQuickCompletionAt
        else {
            return false
        }

        return Date().timeIntervalSince(lastQuickCompletionAt) <= quickCompletionSuggestionWindow
    }

    private func shouldSuggestMarkingPriority(for task: LoopTask) -> Bool {
        prioritySuggestionTaskID == task.id
    }

    private var prioritySuggestionTaskID: UUID? {
        let currentTasks = currentLoopTasks
        guard !currentTasks.contains(where: { !$0.doneThisLoop && $0.isPriority }) else { return nil }
        return currentTasks.first(where: isPrioritySuggestionCandidate)?.id
    }

    private func isPrioritySuggestionCandidate(_ task: LoopTask) -> Bool {
        guard !task.doneThisLoop, !task.isPriority, task.manualFocusCount >= 2 else { return false }
        return currentLoopTasks.contains { $0.id == task.id }
    }

    private func shouldSuggestEditingCadence(for task: LoopTask) -> Bool {
        guard !task.doneThisLoop, task.snoozeCount >= 2 else { return false }
        return task.cadence.rawValue < LoopCadence.everyFourLoops.rawValue
    }

    private func dismissedSuggestion(_ suggestion: LoopTaskSuggestion, for task: LoopTask) -> Bool {
        task.dismissedSuggestions.contains(suggestion)
    }

    @discardableResult
    private func recordFocusStarted(for taskID: UUID, at now: Date = Date()) -> Bool {
        guard isInteractiveTrackingEnabled, activeStartedAt != nil else { return false }
        guard !isOnBreak, !isInMeeting, !isInRoutine else { return false }
        guard focusSessionTracker.taskID != taskID || !focusSessionTracker.isOpen else { return false }
        if focusSessionTracker.isOpen {
            closeTaskFocusSession(at: now)
        }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return false }
        guard focusSessionTracker.start(taskID: taskID, at: now) else { return false }
        tasks[index].focusedAt = now
        if !tasks[index].doneThisLoop {
            tasks[index].lastQuickCompletionAt = nil
        }
        return true
    }

    private func startIterationTimerIfNeeded(for taskID: UUID, resetExisting: Bool = false) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard normalizedIterationTimerMinutes(tasks[index].iterationTimerMinutes) != nil else {
            if tasks[index].iterationTimerStartedAt != nil || tasks[index].iterationTimerStartedLoop != nil {
                tasks[index].iterationTimerStartedAt = nil
                tasks[index].iterationTimerStartedLoop = nil
            }
            return
        }
        guard isInteractiveTrackingEnabled else { return }
        guard !isOnBreak, !isInMeeting, !isInRoutine else { return }
        guard !tasks[index].doneThisLoop, !tasks[index].finished, !tasks[index].isBacklog else { return }
        guard resetExisting || tasks[index].iterationTimerStartedLoop != loopNumber || tasks[index].iterationTimerStartedAt == nil else { return }
        let now = Date()
        currentDate = now
        tasks[index].iterationTimerStartedAt = now
        tasks[index].iterationTimerStartedLoop = loopNumber
    }

    private func recordQuickCompletionIfNeeded(for task: inout LoopTask) {
        let now = Date()
        guard
            focusedTaskID == task.id,
            let focusedAt = task.focusedAt,
            now.timeIntervalSince(focusedAt) <= quickCompletionThreshold
        else {
            return
        }

        task.lastQuickCompletionAt = now
    }

    private func activeSnoozeDate(for task: LoopTask, at date: Date = Date()) -> Date? {
        guard let snoozedUntil = task.snoozedUntil, snoozedUntil > date else { return nil }
        return snoozedUntil
    }

    private func nextWorkingDay(atHour hour: Int, from date: Date) -> Date {
        let calendar = Calendar.current
        var candidate = calendar.startOfDay(for: date)

        repeat {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        } while calendar.isDateInWeekend(candidate)

        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: candidate) ?? candidate
    }

    private func activeScheduledDate(for task: LoopTask, at date: Date? = nil) -> Date? {
        let referenceDate = date ?? currentDate
        guard let scheduledFor = task.scheduledFor, scheduledFor > referenceDate else { return nil }
        return scheduledFor
    }

    private func activeScheduledDate(for routine: RoutineBlock, at date: Date? = nil) -> Date? {
        let now = date ?? currentDate
        return latestScheduledDate(for: routine, at: now).flatMap { scheduledDate in
            if routine.lastCompletedScheduledAt.map({ $0 >= scheduledDate }) == true {
                return nil
            }
            return scheduledDate
        }
    }

    private func latestScheduledDate(for routine: RoutineBlock, at date: Date) -> Date? {
        guard !routine.scheduleTimes.isEmpty else { return nil }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        return routine.scheduleTimes
            .compactMap { scheduleTime in
                calendar.date(bySettingHour: scheduleTime.hour, minute: scheduleTime.minute, second: 0, of: startOfDay)
            }
            .filter { $0 <= date }
            .max()
    }

    private func ordered(_ tasks: [LoopTask]) -> [LoopTask] {
        tasks.sorted(by: isOrderedBefore)
    }

    private func orderedForIteration(_ tasks: [LoopTask]) -> [LoopTask] {
        let orderedTasks = ordered(tasks)
        let readyPriorityTasks = orderedTasks.filter { $0.isPriority && !isPriorityDeferred($0) }
        let deferredPriorityTasks = orderedTasks.filter { $0.isPriority && isPriorityDeferred($0) }
        let regularTasks = orderedTasks.filter { !$0.isPriority }

        if !readyPriorityTasks.isEmpty {
            return readyPriorityTasks + regularTasks + deferredPriorityTasks
        }

        if let firstRegularTask = regularTasks.first, !deferredPriorityTasks.isEmpty {
            return [firstRegularTask] + deferredPriorityTasks + regularTasks.dropFirst()
        }

        return regularTasks + deferredPriorityTasks
    }

    private func isOrderedBefore(_ left: LoopTask, _ right: LoopTask) -> Bool {
        if left.sortOrder == right.sortOrder {
            return left.createdAt < right.createdAt
        }
        return left.sortOrder < right.sortOrder
    }

    private func nextSortOrder() -> Double {
        (tasks.map(\.sortOrder).max() ?? 0) + 1
    }

    private func firstUndoneCurrentTaskID() -> UUID? {
        ordered(tasks.filter {
            !$0.isBacklog
                && !$0.finished
                && !$0.doneThisLoop
                && isDue($0)
                && !isSnoozed($0)
                && !isPriorityDeferred($0)
        }).first?.id
    }

    private func refreshDueItems() {
        guard isInteractiveTrackingEnabled else { return }
        guard !isOnBreak, !isInMeeting, !isInRoutine else { return }
        guard focusedTaskID == nil, currentFocusTaskID != nil else { return }
        ensureFocusedTask()
    }

    @discardableResult
    private func startNextDueRoutineIfReady() -> Bool {
        guard !isOnBreak, !isInMeeting, !isInRoutine else { return false }
        guard let routine = dueRoutineBlocks.first else { return false }
        startRoutineBlock(routine)
        return true
    }

    @discardableResult
    private func markTaskDone(_ task: LoopTask, openNextFocusedApp: Bool) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return false }
        guard !tasks[index].doneThisLoop else { return false }
        if tasks[index].isPriority {
            completePriorityTask(at: index, openNextFocusedApp: openNextFocusedApp)
            return true
        }
        tasks[index].doneThisLoop = true
        tasks[index].lastCompletedLoop = loopNumber
        tasks[index].snoozedUntil = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        recordQuickCompletionIfNeeded(for: &tasks[index])
        clearPriorityDeferrals()
        tasks[index].updatedAt = Date()
        if !focusPriorityAfterRegularTaskCompletion(openNextFocusedApp: openNextFocusedApp),
           !advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: openNextFocusedApp) {
            ensureFocusedTask(openLinkedAppIfChanged: openNextFocusedApp)
        }
        return true
    }

    private func completePriorityTask(at index: Int, openNextFocusedApp: Bool) {
        guard tasks.indices.contains(index), tasks[index].isPriority, !tasks[index].finished else { return }
        tasks[index].doneThisLoop = false
        tasks[index].lastCompletedLoop = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].snoozedUntil = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = Date()
        tasks[index].priorityDeferredLoop = loopNumber
        clearFocusedTask(ifMatching: tasks[index].id)
        if advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: openNextFocusedApp) {
            return
        }
        ensureFocusedTask(openLinkedAppIfChanged: openNextFocusedApp)
    }

    private func isPriorityDeferred(_ task: LoopTask) -> Bool {
        task.priorityDeferredLoop == loopNumber
    }

    private func clearPriorityDeferrals() {
        for index in tasks.indices where tasks[index].priorityDeferredLoop != nil {
            tasks[index].priorityDeferredLoop = nil
            tasks[index].updatedAt = Date()
        }
    }

    private func clearCurrentIterationPriority(except selectedTaskID: UUID) {
        let currentTaskIDs = Set(currentLoopTasks.map(\.id))
        for index in tasks.indices where tasks[index].id != selectedTaskID && currentTaskIDs.contains(tasks[index].id) && tasks[index].isPriority {
            tasks[index].isPriority = false
            tasks[index].priorityDeferredLoop = nil
            tasks[index].updatedAt = Date()
        }
    }

    private func resumeAfterBreak() {
        let shouldFocusPriority = breakShouldFocusPriorityAfterBreak
        breakShouldFocusPriorityAfterBreak = false
        let taskToResume = focusedTaskID

        if shouldFocusPriority, focusPriorityAfterRegularTaskCompletion(openNextFocusedApp: true) {
            return
        }

        if advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: true) {
            return
        }

        ensureFocusedTask(openLinkedAppIfChanged: true)
        if focusedTaskID == taskToResume, let taskToResume {
            recordFocusStarted(for: taskToResume)
        }
    }

    private func focusPriorityAfterRegularTaskCompletion(openNextFocusedApp: Bool) -> Bool {
        guard let priorityTask = currentLoopTasks.first(where: { task in
            task.isPriority
                && !task.doneThisLoop
                && !task.finished
                && !task.isBacklog
                && !isPriorityDeferred(task)
        }) else {
            return false
        }

        setFocusedTaskID(priorityTask.id, openLinkedAppIfChanged: openNextFocusedApp)
        return true
    }

    private func ensureFocusedTask(openLinkedAppIfChanged: Bool = false) {
        guard !isLoading else { return }
        let nextFocusedTaskID = currentFocusTaskID
        setFocusedTaskID(nextFocusedTaskID, openLinkedAppIfChanged: openLinkedAppIfChanged)
    }

    private func setFocusedTaskID(_ nextFocusedTaskID: UUID?, openLinkedAppIfChanged: Bool) {
        let previousFocusedTaskID = focusedTaskID
        let didFocusChange = previousFocusedTaskID != nextFocusedTaskID
        if didFocusChange {
            closeTaskFocusSession(at: Date())
        }
        if focusedTaskID != nextFocusedTaskID {
            focusedTaskID = nextFocusedTaskID
        }
        if (didFocusChange || !focusSessionTracker.isOpen),
           let nextFocusedTaskID,
           recordFocusStarted(for: nextFocusedTaskID) {
            postFocusStarted(.task(nextFocusedTaskID))
        }
        if let nextFocusedTaskID {
            startIterationTimerIfNeeded(for: nextFocusedTaskID, resetExisting: didFocusChange)
        }
        guard
            openLinkedAppIfChanged,
            autoOpenFocusedTaskApp,
            let nextFocusedTaskID,
            let nextFocusedTask = tasks.first(where: { $0.id == nextFocusedTaskID })
        else {
            return
        }

        guard previousFocusedTaskID != nextFocusedTaskID || lastAutoOpenedFocusedTaskID != nextFocusedTaskID else {
            return
        }

        lastAutoOpenedFocusedTaskID = nextFocusedTaskID
        openLinkedApp(for: nextFocusedTask)
    }

    private func applyCurrentLoopTaskOrder(_ loopTasksInOrder: [LoopTask]) {
        var loopTaskIterator = loopTasksInOrder.makeIterator()
        let loopTaskIDs = Set(loopTasksInOrder.map(\.id))
        var globallyOrderedTasks = ordered(tasks).map { task in
            if loopTaskIDs.contains(task.id), let loopTask = loopTaskIterator.next() {
                return loopTask
            }
            return task
        }

        for index in globallyOrderedTasks.indices {
            globallyOrderedTasks[index].sortOrder = Double(index)
        }

        tasks = globallyOrderedTasks
    }

    private func startSnoozeRefreshTimer() {
        snoozeRefreshTimer?.invalidate()
        snoozeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshExpiredSnoozes()
            }
        }
    }

    private func startCountdownRefreshTimer() {
        countdownRefreshTimer?.invalidate()
        countdownRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickCurrentDate()
            }
        }
    }

    private func tickCurrentDate() {
        let now = Date()
        detectSuspensionIfNeeded(at: now, awakeUptime: ProcessInfo.processInfo.systemUptime)
        refreshDueItems()
        if isInteractiveTrackingEnabled,
           trackingHeartbeatAt.map({ now.timeIntervalSince($0) >= trackingHeartbeatInterval }) ?? true {
            trackingHeartbeatAt = now
            save()
        }
    }

    private func detectSuspensionIfNeeded(at now: Date, awakeUptime: TimeInterval) {
        let awakeElapsed = awakeUptime - lastAwakeUptime
        let previousDate = lastTrackingTickDate
        if TimeTracking.suspendedGap(
            from: previousDate,
            to: now,
            awakeElapsed: awakeElapsed
        ) != nil {
            handleDetectedSleepGap(from: previousDate, to: now)
        } else {
            currentDate = now
        }
        lastTrackingTickDate = now
        lastAwakeUptime = awakeUptime
    }

    private func handleDetectedSleepGap(from lastAwakeAt: Date, to wokeAt: Date) {
        let sleepDuration = wokeAt.timeIntervalSince(lastAwakeAt)
        guard sleepDuration > 0 else {
            currentDate = wokeAt
            return
        }

        closeTaskFocusSession(at: lastAwakeAt)
        endActiveSession(at: lastAwakeAt)
        endBreakForSleep(at: lastAwakeAt)
        endMeetingForSleep(at: lastAwakeAt)
        endRoutineForSleep(at: lastAwakeAt)
        isInteractiveTrackingEnabled = false
        if sleepStartedAt == nil {
            sleepStartedAt = lastAwakeAt
        }
        currentDate = wokeAt
        onSuspensionDetected?()
    }

    private func activeBreakDuration(in interval: DateInterval?) -> TimeInterval {
        guard let breakStartedAt else { return 0 }
        let end = max(currentDate, breakStartedAt)
        guard let interval else { return max(0, end.timeIntervalSince(breakStartedAt)) }
        return overlapDuration(start: breakStartedAt, end: end, with: interval)
    }

    private func activeMeetingDuration(in interval: DateInterval?) -> TimeInterval {
        guard let meetingStartedAt else { return 0 }
        let end = max(currentDate, meetingStartedAt)
        guard let interval else { return max(0, end.timeIntervalSince(meetingStartedAt)) }
        return overlapDuration(start: meetingStartedAt, end: end, with: interval)
    }

    private func activeRoutineDuration(in interval: DateInterval?) -> TimeInterval {
        guard let activeRoutineStartedAt else { return 0 }
        let end = boundedRoutineEnd(startedAt: activeRoutineStartedAt, requestedEnd: currentDate)
        guard let interval else { return max(0, end.timeIntervalSince(activeRoutineStartedAt)) }
        return overlapDuration(start: activeRoutineStartedAt, end: end, with: interval)
    }

    private func meetingIntervals(in interval: DateInterval?) -> [DateInterval] {
        var intervals = meetingSessions.compactMap { clippedInterval(start: $0.startedAt, end: $0.endedAt, to: interval) }
        if let meetingStartedAt {
            intervals.append(contentsOf: [clippedInterval(start: meetingStartedAt, end: currentDate, to: interval)].compactMap { $0 })
        }
        return intervals
    }

    private func breakIntervals(in interval: DateInterval?) -> [DateInterval] {
        var intervals = breakSessions.compactMap { clippedInterval(start: $0.startedAt, end: $0.endedAt, to: interval) }
        if let breakStartedAt {
            intervals.append(contentsOf: [clippedInterval(start: breakStartedAt, end: currentDate, to: interval)].compactMap { $0 })
        }
        return intervals
    }

    private func routineIntervals(in interval: DateInterval?, matching predicate: (RoutineSession) -> Bool = { _ in true }) -> [DateInterval] {
        var intervals = routineSessions.compactMap { session in
            predicate(session) ? clippedInterval(start: session.startedAt, end: session.endedAt, to: interval) : nil
        }
        if let activeRoutineStartedAt {
            let activeRoutineEnd = boundedRoutineEnd(
                startedAt: activeRoutineStartedAt,
                requestedEnd: currentDate
            )
            let includeActiveRoutine = activeRoutineBlock.map { block in
                predicate(RoutineSession(
                    routineBlockID: block.id,
                    title: block.title,
                    countsAsProductive: block.countsAsProductive,
                    startedAt: activeRoutineStartedAt,
                    endedAt: activeRoutineEnd
                ))
            } ?? true
            if includeActiveRoutine {
                intervals.append(contentsOf: [clippedInterval(start: activeRoutineStartedAt, end: activeRoutineEnd, to: interval)].compactMap { $0 })
            }
        }
        return intervals
    }

    private func effectiveBreakDuration(in interval: DateInterval?) -> TimeInterval {
        exclusiveDuration(
            of: breakIntervals(in: interval),
            subtracting: meetingIntervals(in: interval)
        )
    }

    private func effectiveRoutineDuration(in interval: DateInterval?) -> TimeInterval {
        exclusiveDuration(
            of: routineIntervals(in: interval),
            subtracting: meetingIntervals(in: interval) + breakIntervals(in: interval)
        )
    }

    private func nonProductiveRoutineDuration(on date: Date) -> TimeInterval {
        guard let interval = Calendar.current.dateInterval(of: .day, for: date) else { return 0 }
        return nonProductiveRoutineDuration(in: interval)
    }

    private func nonProductiveRoutineDuration(in interval: DateInterval?) -> TimeInterval {
        let completedDuration = routineSessions.reduce(0) { total, session in
            guard !session.countsAsProductive else { return total }
            if let interval {
                return total + overlapDuration(start: session.startedAt, end: session.endedAt, with: interval)
            }
            return total + max(0, session.endedAt.timeIntervalSince(session.startedAt))
        }

        guard activeRoutineBlock?.countsAsProductive == false else { return completedDuration }
        return completedDuration + activeRoutineDuration(in: interval)
    }

    private func productiveRoutineDuration(in interval: DateInterval?) -> TimeInterval {
        exclusiveDuration(
            of: routineIntervals(in: interval) { $0.countsAsProductive },
            subtracting: meetingIntervals(in: interval) + breakIntervals(in: interval)
        )
    }

    private func activeComputerDuration(in interval: DateInterval?) -> TimeInterval {
        guard let activeStartedAt else { return 0 }
        let end = max(currentDate, activeStartedAt)
        guard let interval else { return max(0, end.timeIntervalSince(activeStartedAt)) }
        return overlapDuration(start: activeStartedAt, end: end, with: interval)
    }

    private func activeWorkDuration(in interval: DateInterval?) -> TimeInterval {
        duration(of: activeWorkIntervals(in: interval))
    }

    private func activeWorkBounds(in interval: DateInterval?) -> DateInterval? {
        let intervals = activeWorkIntervals(in: interval)
        guard
            let firstStart = intervals.map(\.start).min(),
            let lastEnd = intervals.map(\.end).max(),
            lastEnd > firstStart
        else {
            return nil
        }
        return DateInterval(start: firstStart, end: lastEnd)
    }

    private func activeWorkIntervals(in interval: DateInterval?) -> [DateInterval] {
        let activeIntervals = mergedIntervals(activeComputerIntervals(in: interval))
        let blockedIntervals = mergedIntervals(blockedComputerIntervals(in: interval))
        guard !activeIntervals.isEmpty else { return [] }
        guard !blockedIntervals.isEmpty else { return activeIntervals }

        return activeIntervals.flatMap { activeInterval in
            remainingIntervals(of: activeInterval, subtracting: blockedIntervals)
        }
    }

    private func activeComputerIntervals(in interval: DateInterval?) -> [DateInterval] {
        var intervals = activeSessions.compactMap { clippedInterval(start: $0.startedAt, end: $0.endedAt, to: interval) }
        if let activeStartedAt {
            intervals.append(contentsOf: [clippedInterval(start: activeStartedAt, end: max(currentDate, activeStartedAt), to: interval)].compactMap { $0 })
        }
        return intervals
    }

    private func blockedComputerIntervals(in interval: DateInterval?) -> [DateInterval] {
        var intervals: [DateInterval] = []
        intervals.append(contentsOf: breakSessions.compactMap { clippedInterval(start: $0.startedAt, end: $0.endedAt, to: interval) })
        intervals.append(contentsOf: meetingSessions.compactMap { clippedInterval(start: $0.startedAt, end: $0.endedAt, to: interval) })
        intervals.append(contentsOf: routineSessions.compactMap { clippedInterval(start: $0.startedAt, end: $0.endedAt, to: interval) })

        if let breakStartedAt {
            intervals.append(contentsOf: [clippedInterval(start: breakStartedAt, end: currentDate, to: interval)].compactMap { $0 })
        }
        if let meetingStartedAt {
            intervals.append(contentsOf: [clippedInterval(start: meetingStartedAt, end: currentDate, to: interval)].compactMap { $0 })
        }
        if let activeRoutineStartedAt {
            let activeRoutineEnd = boundedRoutineEnd(
                startedAt: activeRoutineStartedAt,
                requestedEnd: currentDate
            )
            intervals.append(contentsOf: [clippedInterval(start: activeRoutineStartedAt, end: activeRoutineEnd, to: interval)].compactMap { $0 })
        }
        return intervals
    }

    private func clippedInterval(start: Date, end: Date, to interval: DateInterval?) -> DateInterval? {
        TimeTracking.clippedInterval(start: start, end: end, to: interval)
    }

    private func mergedIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        TimeTracking.mergedIntervals(intervals)
    }

    private func duration(of intervals: [DateInterval]) -> TimeInterval {
        TimeTracking.totalDuration(of: intervals)
    }

    private func exclusiveDuration(of intervals: [DateInterval], subtracting blockedIntervals: [DateInterval]) -> TimeInterval {
        TimeTracking.exclusiveDuration(of: intervals, subtracting: blockedIntervals)
    }

    private func remainingIntervals(of interval: DateInterval, subtracting blockedIntervals: [DateInterval]) -> [DateInterval] {
        TimeTracking.subtracting(blockedIntervals, from: [interval])
    }

    private func overlapDuration(start: Date, end: Date, with interval: DateInterval) -> TimeInterval {
        let overlapStart = max(start, interval.start)
        let overlapEnd = min(end, interval.end)
        return max(0, overlapEnd.timeIntervalSince(overlapStart))
    }

    private func normalizedIterationTimerMinutes(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0 else { return nil }
        return min(minutes, 24 * 60)
    }

    private func normalizedRoutineDurationMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 1), 240)
    }

    private func normalizedScheduleTimes(_ scheduleTimes: [DailyScheduleTime]) -> [DailyScheduleTime] {
        Array(Set(scheduleTimes.map { DailyScheduleTime(hour: $0.hour, minute: $0.minute) })).sorted()
    }

    private func orderedRoutines(_ routines: [RoutineBlock]) -> [RoutineBlock] {
        routines.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.createdAt < $1.createdAt
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private func nextRoutineSortOrder() -> Double {
        (routineBlocks.map(\.sortOrder).max() ?? 0) + 1
    }

    private func refreshExpiredSnoozes() {
        let now = Date()
        var didChange = false
        for index in tasks.indices where tasks[index].snoozedUntil.map({ $0 <= now }) == true {
            tasks[index].snoozedUntil = nil
            tasks[index].updatedAt = now
            didChange = true
        }

        if didChange, isInteractiveTrackingEnabled {
            ensureFocusedTask()
        }
    }

    private func recoverInterruptedTracking(activeStartedAt persistedActiveStart: Date?, heartbeatAt: Date?) {
        let loadNow = Date()
        trackingHeartbeatAt = heartbeatAt

        let persistedSleepStart = sleepStartedAt.flatMap { $0 <= loadNow ? $0 : nil }
        let heartbeatRecoveryEnd = TimeTracking.recoveryEnd(heartbeat: heartbeatAt, now: loadNow)
        let recoveryEnd: Date?
        switch (persistedSleepStart, heartbeatRecoveryEnd) {
        case let (sleepStart?, heartbeat?):
            recoveryEnd = min(sleepStart, heartbeat)
        case let (sleepStart?, nil):
            recoveryEnd = sleepStart
        case let (nil, heartbeat?):
            recoveryEnd = heartbeat
        case (nil, nil):
            recoveryEnd = nil
        }

        let hasOpenTracking = persistedActiveStart != nil
            || breakStartedAt != nil
            || meetingStartedAt != nil
            || activeRoutineBlockID != nil
            || activeRoutineStartedAt != nil

        guard hasOpenTracking else {
            discardOpenTracking(resetIterationTimers: false)
            return
        }
        guard let recoveryEnd else {
            discardOpenTracking(resetIterationTimers: true)
            return
        }

        if let persistedActiveStart, persistedActiveStart < recoveryEnd {
            activeSessions.append(ActiveSession(
                startedAt: persistedActiveStart,
                endedAt: recoveryEnd
            ))
        }

        if persistedActiveStart != nil,
           let focusedTaskID,
           let focusStart = tasks.first(where: { $0.id == focusedTaskID })?.focusedAt,
           focusStart < recoveryEnd {
            taskFocusSessions.append(TaskFocusSession(
                taskID: focusedTaskID,
                startedAt: focusStart,
                endedAt: recoveryEnd
            ))
        }

        var recoveredBlockedIntervals: [DateInterval] = []
        if let breakStartedAt, breakStartedAt < recoveryEnd {
            breakSessions.append(BreakSession(startedAt: breakStartedAt, endedAt: recoveryEnd))
            recoveredBlockedIntervals.append(DateInterval(start: breakStartedAt, end: recoveryEnd))
        }
        if let meetingStartedAt, meetingStartedAt < recoveryEnd {
            meetingSessions.append(MeetingSession(startedAt: meetingStartedAt, endedAt: recoveryEnd))
            recoveredBlockedIntervals.append(DateInterval(start: meetingStartedAt, end: recoveryEnd))
        }
        if let activeRoutineBlockID,
           let activeRoutineStartedAt,
           activeRoutineStartedAt < recoveryEnd {
            let recoveredRoutineEnd = boundedRoutineEnd(
                startedAt: activeRoutineStartedAt,
                requestedEnd: recoveryEnd
            )
            let routine = routineBlocks.first { $0.id == activeRoutineBlockID }
            if isValidRoutineSession(startedAt: activeRoutineStartedAt, endedAt: recoveredRoutineEnd) {
                routineSessions.append(RoutineSession(
                    routineBlockID: activeRoutineBlockID,
                    title: routine?.title ?? "Routine",
                    countsAsProductive: routine?.countsAsProductive ?? true,
                    startedAt: activeRoutineStartedAt,
                    endedAt: recoveredRoutineEnd
                ))
                recoveredBlockedIntervals.append(DateInterval(start: activeRoutineStartedAt, end: recoveredRoutineEnd))
            }
        }
        for blockedInterval in TimeTracking.mergedIntervals(recoveredBlockedIntervals) {
            pauseIterationTimers(by: blockedInterval.duration)
        }

        discardOpenTracking(resetIterationTimers: false)
        if sleepStartedAt == nil || sleepStartedAt.map({ $0 > recoveryEnd }) == true {
            sleepStartedAt = recoveryEnd
        }
    }

    private func discardOpenTracking(resetIterationTimers: Bool) {
        activeStartedAt = nil
        focusSessionTracker.reset()
        breakStartedAt = nil
        breakUntil = nil
        breakShouldFocusPriorityAfterBreak = false
        meetingStartedAt = nil
        activeRoutineBlockID = nil
        activeRoutineStartedAt = nil
        activeRoutineUntil = nil
        activeRoutineScheduledAt = nil
        for index in tasks.indices {
            tasks[index].focusedAt = nil
            if resetIterationTimers {
                tasks[index].iterationTimerStartedAt = nil
                tasks[index].iterationTimerStartedLoop = nil
            }
        }
    }

    private func sanitizeActiveTrackingAfterLoad() {
        activeSessions = deduplicatedActiveSessions(activeSessions)
        breakSessions = deduplicatedBreakSessions(breakSessions)
        meetingSessions = deduplicatedMeetingSessions(meetingSessions)
        routineSessions = deduplicatedRoutineSessions(routineSessions)
        taskFocusSessions = deduplicatedTaskFocusSessions(taskFocusSessions)
        activeStartedAt = nil
        focusSessionTracker.reset()
        for index in tasks.indices {
            tasks[index].focusedAt = nil
        }
    }

    private func deduplicatedActiveSessions(_ sessions: [ActiveSession]) -> [ActiveSession] {
        coalescedOverlappingIntervals(sessions.map { ($0.startedAt, $0.endedAt) })
            .map { ActiveSession(startedAt: $0.start, endedAt: $0.end) }
    }

    private func deduplicatedBreakSessions(_ sessions: [BreakSession]) -> [BreakSession] {
        coalescedOverlappingIntervals(sessions.map { ($0.startedAt, $0.endedAt) })
            .map { BreakSession(startedAt: $0.start, endedAt: $0.end) }
    }

    private func deduplicatedMeetingSessions(_ sessions: [MeetingSession]) -> [MeetingSession] {
        coalescedOverlappingIntervals(sessions.map { ($0.startedAt, $0.endedAt) })
            .map { MeetingSession(startedAt: $0.start, endedAt: $0.end) }
    }

    private func deduplicatedRoutineSessions(_ sessions: [RoutineSession]) -> [RoutineSession] {
        Dictionary(grouping: sessions) { session in
            RoutineSessionMetadataKey(
                routineBlockID: session.routineBlockID,
                title: session.title,
                countsAsProductive: session.countsAsProductive
            )
        }
            .flatMap { metadata, routineSessions -> [RoutineSession] in
                return coalescedOverlappingIntervals(routineSessions.map { ($0.startedAt, $0.endedAt) })
                    .map { interval in
                        (
                            start: interval.start,
                            end: min(
                                interval.end,
                                interval.start.addingTimeInterval(maximumRecoveredRoutineDuration)
                            )
                        )
                    }
                    .filter { isValidRoutineSession(startedAt: $0.start, endedAt: $0.end) }
                    .map {
                        RoutineSession(
                            routineBlockID: metadata.routineBlockID,
                            title: metadata.title,
                            countsAsProductive: metadata.countsAsProductive,
                            startedAt: $0.start,
                            endedAt: $0.end
                        )
                    }
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func deduplicatedTaskFocusSessions(_ sessions: [TaskFocusSession]) -> [TaskFocusSession] {
        Dictionary(grouping: sessions, by: \.taskID)
            .flatMap { taskID, focusSessions in
                coalescedOverlappingIntervals(focusSessions.map { ($0.startedAt, $0.endedAt) })
                    .map { TaskFocusSession(taskID: taskID, startedAt: $0.start, endedAt: $0.end) }
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func coalescedOverlappingIntervals(_ intervals: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        intervals
            .filter { $0.end > $0.start }
            .sorted { left, right in
                left.start == right.start ? left.end < right.end : left.start < right.start
            }
            .reduce(into: []) { result, interval in
                guard let previous = result.last, interval.start < previous.end else {
                    result.append(interval)
                    return
                }
                result[result.count - 1] = (previous.start, max(previous.end, interval.end))
            }
    }

    private func recordAction(_ action: LoopAction) {
        actionCounts[action.rawValue, default: 0] += 1
    }

    private func isValidRoutineSession(startedAt: Date, endedAt: Date) -> Bool {
        guard endedAt > startedAt else { return false }
        return endedAt.timeIntervalSince(startedAt) <= maximumRecoveredRoutineDuration
    }

    private func boundedRoutineEnd(startedAt: Date, requestedEnd: Date) -> Date {
        let hardLimit = startedAt.addingTimeInterval(maximumRecoveredRoutineDuration)
        let configuredLimit = min(activeRoutineUntil ?? hardLimit, hardLimit)
        let trustedLimit = max(startedAt, configuredLimit)
        return min(max(requestedEnd, startedAt), trustedLimit)
    }

    private func save() {
        guard !isLoading else { return }
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func flushPendingSave() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        saveNow()
    }

    private func saveNow() {
        guard !isLoading else { return }
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        let snapshot = StoreSnapshot(
            tasks: tasks,
            loopNumber: loopNumber,
            loopCompletions: loopCompletions,
            breakSessions: breakSessions,
            meetingSessions: meetingSessions,
            routineBlocks: routineBlocks,
            routineSessions: routineSessions,
            activeSessions: activeSessions,
            taskFocusSessions: taskFocusSessions,
            actionCounts: actionCounts,
            focusedTaskID: focusedTaskID,
            autoOpenFocusedTaskApp: autoOpenFocusedTaskApp,
            dismissedFastLoopSuggestionAt: dismissedFastLoopSuggestionAt,
            morningOnboardingShownAt: morningOnboardingShownAt,
            breakStartedAt: breakStartedAt,
            breakUntil: breakUntil,
            breakShouldFocusPriorityAfterBreak: breakShouldFocusPriorityAfterBreak,
            meetingStartedAt: meetingStartedAt,
            activeRoutineBlockID: activeRoutineBlockID,
            activeRoutineStartedAt: activeRoutineStartedAt,
            activeRoutineUntil: activeRoutineUntil,
            activeRoutineScheduledAt: activeRoutineScheduledAt,
            activeStartedAt: activeStartedAt,
            trackingHeartbeatAt: trackingHeartbeatAt,
            sleepStartedAt: sleepStartedAt,
            breakDurationMinutes: breakDurationMinutes,
            defaultIterationTimerMinutes: defaultIterationTimerMinutes,
            newTasksStartInCurrentIteration: newTasksStartInCurrentIteration,
            shortcut: shortcut.normalized,
            doneShortcut: doneShortcut.normalized,
            quickAddShortcut: quickAddShortcut.normalized,
            breakShortcut: breakShortcut.normalized
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let snapshot = try? JSONDecoder().decode(StoreSnapshot.self, from: data)
        else {
            return
        }

        isLoading = true
        defer {
            isLoading = false
            currentDate = Date()
            if !isOnBreak, !isInMeeting, !isInRoutine {
                ensureFocusedTask()
            }
            save()
        }

        loopNumber = max(1, snapshot.loopNumber)
        loopCompletions = snapshot.loopCompletions
        breakSessions = snapshot.breakSessions
        meetingSessions = snapshot.meetingSessions
        routineBlocks = snapshot.routineBlocks
        routineSessions = snapshot.routineSessions
        activeSessions = snapshot.activeSessions
        taskFocusSessions = snapshot.taskFocusSessions
        actionCounts = snapshot.actionCounts
        focusedTaskID = snapshot.focusedTaskID
        autoOpenFocusedTaskApp = snapshot.autoOpenFocusedTaskApp
        openLoopAtLogin = LoginLaunchAgent.isEnabled
        dismissedFastLoopSuggestionAt = snapshot.dismissedFastLoopSuggestionAt
        morningOnboardingShownAt = snapshot.morningOnboardingShownAt
        breakStartedAt = snapshot.breakStartedAt
        breakUntil = snapshot.breakUntil
        breakShouldFocusPriorityAfterBreak = snapshot.breakShouldFocusPriorityAfterBreak
        meetingStartedAt = snapshot.meetingStartedAt
        activeRoutineBlockID = snapshot.activeRoutineBlockID
        activeRoutineStartedAt = snapshot.activeRoutineStartedAt
        activeRoutineUntil = snapshot.activeRoutineUntil
        activeRoutineScheduledAt = snapshot.activeRoutineScheduledAt
        activeStartedAt = nil
        trackingHeartbeatAt = snapshot.trackingHeartbeatAt
        sleepStartedAt = snapshot.sleepStartedAt
        breakDurationMinutes = min(max(snapshot.breakDurationMinutes, 1), 120)
        defaultIterationTimerMinutes = min(max(snapshot.defaultIterationTimerMinutes, 0), 240)
        newTasksStartInCurrentIteration = snapshot.newTasksStartInCurrentIteration
        doneShortcut = snapshot.doneShortcut.normalized
        quickAddShortcut = snapshot.quickAddShortcut.normalized
        breakShortcut = snapshot.breakShortcut.normalized
        tasks = snapshot.tasks.map { task in
            var migratedTask = task
            migratedTask.createdLoop = migratedTask.createdLoop ?? loopNumber
            if migratedTask.doneThisLoop && migratedTask.lastCompletedLoop == nil {
                migratedTask.lastCompletedLoop = loopNumber
            }
            if migratedTask.finished {
                migratedTask.finishedLoop = migratedTask.finishedLoop ?? loopNumber
                migratedTask.finishedAt = migratedTask.finishedAt ?? migratedTask.updatedAt
            }
            if migratedTask.isPriority && !migratedTask.finished {
                migratedTask.doneThisLoop = false
                migratedTask.lastCompletedLoop = nil
                migratedTask.lastQuickCompletionAt = nil
                if migratedTask.priorityDeferredLoop != loopNumber {
                    migratedTask.priorityDeferredLoop = nil
                }
            } else {
                migratedTask.priorityDeferredLoop = nil
            }
            return migratedTask
        }
        routineBlocks = orderedRoutines(snapshot.routineBlocks).map { routine in
            var migratedRoutine = routine
            migratedRoutine.title = migratedRoutine.title.trimmingCharacters(in: .whitespacesAndNewlines)
            migratedRoutine.durationMinutes = normalizedRoutineDurationMinutes(migratedRoutine.durationMinutes)
            migratedRoutine.scheduleTimes = normalizedScheduleTimes(migratedRoutine.scheduleTimes)
            return migratedRoutine
        }
        if activeRoutineBlockID.map({ id in !routineBlocks.contains { $0.id == id } }) == true {
            activeRoutineBlockID = nil
            activeRoutineStartedAt = nil
            activeRoutineUntil = nil
            activeRoutineScheduledAt = nil
        }
        recoverInterruptedTracking(
            activeStartedAt: snapshot.activeStartedAt,
            heartbeatAt: snapshot.trackingHeartbeatAt
        )
        sanitizeActiveTrackingAfterLoad()
        shortcut = snapshot.shortcut.normalized
    }
}

private struct RoutineSessionMetadataKey: Hashable {
    var routineBlockID: UUID
    var title: String
    var countsAsProductive: Bool
}

struct ActionTelemetryStat: Identifiable, Equatable {
    var id: String
    var title: String
    var count: Int
    var systemImage: String
    var category: ActionTelemetryCategory
}

enum ActionTelemetryCategory: String, CaseIterable, Identifiable {
    case all
    case tasks
    case routines
    case flow
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .tasks: "Tasks"
        case .routines: "Routines"
        case .flow: "Flow"
        case .settings: "Settings"
        }
    }
}

private enum LoopAction: String, CaseIterable {
    case addTask
    case addBacklogTask
    case updateTask
    case renameTask
    case completeTask
    case completeFocusedTask
    case reopenTask
    case finishTask
    case restoreTask
    case deleteTask
    case addToIteration
    case moveToBacklog
    case markPriority
    case removePriority
    case focusTask
    case snoozeTask
    case unsnoozeTask
    case clearSchedule
    case scheduleForNextWorkingDay
    case extendTimer
    case reorderTask
    case advanceLoop
    case resetLoop
    case startBreak
    case endBreak
    case startMeeting
    case endMeeting
    case addRoutine
    case updateRoutine
    case deleteRoutine
    case startRoutine
    case completeRoutine
    case skipRoutine
    case reopenRoutine
    case setAutoOpenFocusedTaskApp
    case setOpenLoopAtLogin
    case setBreakDuration
    case setDefaultIterationTimer
    case dismissSuggestion
    case dismissFastLoopSuggestion
    case completeMorningPlan

    var title: String {
        switch self {
        case .addTask: "Add task"
        case .addBacklogTask: "Add later task"
        case .updateTask: "Edit task details"
        case .renameTask: "Rename task"
        case .completeTask: "Complete task"
        case .completeFocusedTask: "Complete focused task"
        case .reopenTask: "Reopen task"
        case .finishTask: "Finish task"
        case .restoreTask: "Restore task"
        case .deleteTask: "Delete task"
        case .addToIteration: "Add to iteration"
        case .moveToBacklog: "Move to later"
        case .markPriority: "Mark priority"
        case .removePriority: "Remove priority"
        case .focusTask: "Focus task"
        case .snoozeTask: "Snooze task"
        case .unsnoozeTask: "Unsnooze task"
        case .clearSchedule: "Add scheduled task now"
        case .scheduleForNextWorkingDay: "Schedule for next working day"
        case .extendTimer: "Extend timer"
        case .reorderTask: "Reorder task"
        case .advanceLoop: "Advance iteration"
        case .resetLoop: "Reset iteration"
        case .startBreak: "Start break"
        case .endBreak: "End break"
        case .startMeeting: "Start meeting"
        case .endMeeting: "End meeting"
        case .addRoutine: "Add routine"
        case .updateRoutine: "Edit routine"
        case .deleteRoutine: "Delete routine"
        case .startRoutine: "Start routine"
        case .completeRoutine: "Complete routine"
        case .skipRoutine: "Skip routine"
        case .reopenRoutine: "Reopen routine"
        case .setAutoOpenFocusedTaskApp: "Toggle auto-open app"
        case .setOpenLoopAtLogin: "Toggle login launch"
        case .setBreakDuration: "Change break duration"
        case .setDefaultIterationTimer: "Change default timer"
        case .dismissSuggestion: "Dismiss suggestion"
        case .dismissFastLoopSuggestion: "Dismiss fast-loop suggestion"
        case .completeMorningPlan: "Complete morning plan"
        }
    }

    var systemImage: String {
        switch self {
        case .addTask, .addBacklogTask, .addRoutine: "plus.circle"
        case .updateTask, .renameTask, .updateRoutine: "pencil"
        case .completeTask, .completeFocusedTask, .completeRoutine, .completeMorningPlan: "checkmark.circle"
        case .reopenTask, .restoreTask, .reopenRoutine: "arrow.uturn.backward.circle"
        case .finishTask: "checkmark.seal"
        case .deleteTask, .deleteRoutine: "trash"
        case .addToIteration: "arrow.up.circle"
        case .moveToBacklog: "tray.and.arrow.down"
        case .markPriority, .removePriority: "star"
        case .focusTask: "scope"
        case .snoozeTask, .unsnoozeTask: "clock"
        case .clearSchedule, .scheduleForNextWorkingDay: "calendar.badge.clock"
        case .extendTimer, .setDefaultIterationTimer: "timer"
        case .reorderTask: "arrow.up.arrow.down"
        case .advanceLoop, .resetLoop: "arrow.triangle.2.circlepath"
        case .startBreak, .endBreak, .setBreakDuration: "cup.and.saucer"
        case .startMeeting, .endMeeting: "video"
        case .startRoutine, .skipRoutine: "play.circle"
        case .setAutoOpenFocusedTaskApp: "app.badge"
        case .setOpenLoopAtLogin: "power"
        case .dismissSuggestion, .dismissFastLoopSuggestion: "xmark.circle"
        }
    }

    var category: ActionTelemetryCategory {
        switch self {
        case .addTask, .addBacklogTask, .updateTask, .renameTask, .completeTask, .completeFocusedTask,
             .reopenTask, .finishTask, .restoreTask, .deleteTask, .addToIteration, .moveToBacklog,
             .markPriority, .removePriority, .focusTask, .snoozeTask, .unsnoozeTask, .clearSchedule,
             .scheduleForNextWorkingDay,
             .extendTimer, .reorderTask:
            return .tasks
        case .addRoutine, .updateRoutine, .deleteRoutine, .startRoutine, .completeRoutine, .skipRoutine,
             .reopenRoutine:
            return .routines
        case .advanceLoop, .resetLoop, .startBreak, .endBreak, .startMeeting, .endMeeting,
             .dismissSuggestion, .dismissFastLoopSuggestion, .completeMorningPlan:
            return .flow
        case .setAutoOpenFocusedTaskApp, .setOpenLoopAtLogin, .setBreakDuration, .setDefaultIterationTimer:
            return .settings
        }
    }
}

private struct StoreSnapshot: Codable {
    var tasks: [LoopTask]
    var loopNumber: Int
    var loopCompletions: [LoopCompletion]
    var breakSessions: [BreakSession]
    var meetingSessions: [MeetingSession]
    var routineBlocks: [RoutineBlock]
    var routineSessions: [RoutineSession]
    var activeSessions: [ActiveSession]
    var taskFocusSessions: [TaskFocusSession]
    var actionCounts: [String: Int]
    var focusedTaskID: UUID?
    var autoOpenFocusedTaskApp: Bool
    var dismissedFastLoopSuggestionAt: Date?
    var morningOnboardingShownAt: Date?
    var breakStartedAt: Date?
    var breakUntil: Date?
    var breakShouldFocusPriorityAfterBreak: Bool
    var meetingStartedAt: Date?
    var activeRoutineBlockID: UUID?
    var activeRoutineStartedAt: Date?
    var activeRoutineUntil: Date?
    var activeRoutineScheduledAt: Date?
    var activeStartedAt: Date?
    var trackingHeartbeatAt: Date?
    var sleepStartedAt: Date?
    var breakDurationMinutes: Int
    var defaultIterationTimerMinutes: Int
    var newTasksStartInCurrentIteration: Bool
    var shortcut: KeyboardShortcutSetting
    var doneShortcut: KeyboardShortcutSetting
    var quickAddShortcut: KeyboardShortcutSetting
    var breakShortcut: KeyboardShortcutSetting

    private enum CodingKeys: String, CodingKey {
        case tasks
        case loopNumber
        case loopCompletions
        case breakSessions
        case meetingSessions
        case routineBlocks
        case routineSessions
        case activeSessions
        case taskFocusSessions
        case actionCounts
        case focusedTaskID
        case autoOpenFocusedTaskApp
        case dismissedFastLoopSuggestionAt
        case morningOnboardingShownAt
        case breakStartedAt
        case breakUntil
        case breakShouldFocusPriorityAfterBreak
        case meetingStartedAt
        case activeRoutineBlockID
        case activeRoutineStartedAt
        case activeRoutineUntil
        case activeRoutineScheduledAt
        case activeStartedAt
        case trackingHeartbeatAt
        case sleepStartedAt
        case breakDurationMinutes
        case defaultIterationTimerMinutes
        case newTasksStartInCurrentIteration
        case shortcut
        case doneShortcut
        case quickAddShortcut
        case breakShortcut
    }

    init(
        tasks: [LoopTask],
        loopNumber: Int,
        loopCompletions: [LoopCompletion],
        breakSessions: [BreakSession],
        meetingSessions: [MeetingSession],
        routineBlocks: [RoutineBlock],
        routineSessions: [RoutineSession],
        activeSessions: [ActiveSession],
        taskFocusSessions: [TaskFocusSession],
        actionCounts: [String: Int],
        focusedTaskID: UUID?,
        autoOpenFocusedTaskApp: Bool,
        dismissedFastLoopSuggestionAt: Date?,
        morningOnboardingShownAt: Date?,
        breakStartedAt: Date?,
        breakUntil: Date?,
        breakShouldFocusPriorityAfterBreak: Bool,
        meetingStartedAt: Date?,
        activeRoutineBlockID: UUID?,
        activeRoutineStartedAt: Date?,
        activeRoutineUntil: Date?,
        activeRoutineScheduledAt: Date?,
        activeStartedAt: Date?,
        trackingHeartbeatAt: Date?,
        sleepStartedAt: Date?,
        breakDurationMinutes: Int,
        defaultIterationTimerMinutes: Int,
        newTasksStartInCurrentIteration: Bool,
        shortcut: KeyboardShortcutSetting,
        doneShortcut: KeyboardShortcutSetting,
        quickAddShortcut: KeyboardShortcutSetting,
        breakShortcut: KeyboardShortcutSetting
    ) {
        self.tasks = tasks
        self.loopNumber = loopNumber
        self.loopCompletions = loopCompletions
        self.breakSessions = breakSessions
        self.meetingSessions = meetingSessions
        self.routineBlocks = routineBlocks
        self.routineSessions = routineSessions
        self.activeSessions = activeSessions
        self.taskFocusSessions = taskFocusSessions
        self.actionCounts = actionCounts
        self.focusedTaskID = focusedTaskID
        self.autoOpenFocusedTaskApp = autoOpenFocusedTaskApp
        self.dismissedFastLoopSuggestionAt = dismissedFastLoopSuggestionAt
        self.morningOnboardingShownAt = morningOnboardingShownAt
        self.breakStartedAt = breakStartedAt
        self.breakUntil = breakUntil
        self.breakShouldFocusPriorityAfterBreak = breakShouldFocusPriorityAfterBreak
        self.meetingStartedAt = meetingStartedAt
        self.activeRoutineBlockID = activeRoutineBlockID
        self.activeRoutineStartedAt = activeRoutineStartedAt
        self.activeRoutineUntil = activeRoutineUntil
        self.activeRoutineScheduledAt = activeRoutineScheduledAt
        self.activeStartedAt = activeStartedAt
        self.trackingHeartbeatAt = trackingHeartbeatAt
        self.sleepStartedAt = sleepStartedAt
        self.breakDurationMinutes = breakDurationMinutes
        self.defaultIterationTimerMinutes = defaultIterationTimerMinutes
        self.newTasksStartInCurrentIteration = newTasksStartInCurrentIteration
        self.shortcut = shortcut
        self.doneShortcut = doneShortcut
        self.quickAddShortcut = quickAddShortcut
        self.breakShortcut = breakShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = container.decodeLossyArray([LoopTask].self, forKey: .tasks)
        loopNumber = try container.decodeIfPresent(Int.self, forKey: .loopNumber) ?? 1
        loopCompletions = container.decodeLossyArray([LoopCompletion].self, forKey: .loopCompletions)
        breakSessions = container.decodeLossyArray([BreakSession].self, forKey: .breakSessions)
        meetingSessions = container.decodeLossyArray([MeetingSession].self, forKey: .meetingSessions)
        routineBlocks = container.decodeLossyArray([RoutineBlock].self, forKey: .routineBlocks)
        routineSessions = container.decodeLossyArray([RoutineSession].self, forKey: .routineSessions)
        activeSessions = container.decodeLossyArray([ActiveSession].self, forKey: .activeSessions)
        taskFocusSessions = container.decodeLossyArray([TaskFocusSession].self, forKey: .taskFocusSessions)
        actionCounts = try container.decodeIfPresent([String: Int].self, forKey: .actionCounts) ?? [:]
        focusedTaskID = try container.decodeIfPresent(UUID.self, forKey: .focusedTaskID)
        autoOpenFocusedTaskApp = try container.decodeIfPresent(Bool.self, forKey: .autoOpenFocusedTaskApp) ?? true
        dismissedFastLoopSuggestionAt = try container.decodeIfPresent(Date.self, forKey: .dismissedFastLoopSuggestionAt)
        morningOnboardingShownAt = try container.decodeIfPresent(Date.self, forKey: .morningOnboardingShownAt)
        breakStartedAt = try container.decodeIfPresent(Date.self, forKey: .breakStartedAt)
        breakUntil = try container.decodeIfPresent(Date.self, forKey: .breakUntil)
        breakShouldFocusPriorityAfterBreak = try container.decodeIfPresent(Bool.self, forKey: .breakShouldFocusPriorityAfterBreak) ?? false
        meetingStartedAt = try container.decodeIfPresent(Date.self, forKey: .meetingStartedAt)
        activeRoutineBlockID = try container.decodeIfPresent(UUID.self, forKey: .activeRoutineBlockID)
        activeRoutineStartedAt = try container.decodeIfPresent(Date.self, forKey: .activeRoutineStartedAt)
        activeRoutineUntil = try container.decodeIfPresent(Date.self, forKey: .activeRoutineUntil)
        activeRoutineScheduledAt = try container.decodeIfPresent(Date.self, forKey: .activeRoutineScheduledAt)
        activeStartedAt = try container.decodeIfPresent(Date.self, forKey: .activeStartedAt)
        trackingHeartbeatAt = try container.decodeIfPresent(Date.self, forKey: .trackingHeartbeatAt)
        sleepStartedAt = try container.decodeIfPresent(Date.self, forKey: .sleepStartedAt)
        breakDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .breakDurationMinutes) ?? 5
        defaultIterationTimerMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultIterationTimerMinutes) ?? 2
        newTasksStartInCurrentIteration = try container.decodeIfPresent(Bool.self, forKey: .newTasksStartInCurrentIteration) ?? true
        shortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .shortcut) ?? .defaultShortcut
        doneShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .doneShortcut) ?? .defaultDoneShortcut
        quickAddShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .quickAddShortcut) ?? .defaultQuickAddShortcut
        breakShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .breakShortcut) ?? .defaultBreakShortcut
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyArray<Element: Decodable>(_ type: [Element].Type, forKey key: Key) -> [Element] {
        (try? decodeIfPresent(LossyDecodableList<Element>.self, forKey: key))??.elements ?? []
    }
}

private struct LossyDecodableList<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(DiscardedDecodable.self)
            }
        }
    }
}

private struct DiscardedDecodable: Decodable {
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try? container.decode(DiscardedDecodable.self)
            }
            return
        }

        if let container = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in container.allKeys {
                _ = try? container.decode(DiscardedDecodable.self, forKey: key)
            }
            return
        }

        _ = try? decoder.singleValueContainer().decode(Bool.self)
        _ = try? decoder.singleValueContainer().decode(Double.self)
        _ = try? decoder.singleValueContainer().decode(String.self)
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum FocusModeExit: String {
    case `break`
    case routine
    case meeting
}

enum FocusStart: Equatable {
    case `break`
    case routine(UUID)
    case task(UUID)
}

private extension TaskStore {
    func postFocusModeEnded(_ mode: FocusModeExit) {
        NotificationCenter.default.post(name: .loopFocusModeDidEnd, object: mode)
    }

    func postFocusStarted(_ start: FocusStart) {
        NotificationCenter.default.post(name: .loopFocusDidStart, object: start)
    }
}

private enum LoginLaunchAgent {
    private static var label: String {
        Bundle.main.bundleIdentifier ?? "local.loop.menubar"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        try FileManager.default.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/\(label).out.log",
            "StandardErrorPath": "/tmp/\(label).err.log"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)

        try? runLaunchctl(arguments: ["bootout", guiDomain, plistURL.path])
        try runLaunchctl(arguments: ["bootstrap", guiDomain, plistURL.path])
        try runLaunchctl(arguments: ["kickstart", "-k", "\(guiDomain)/\(label)"])
    }

    private static func uninstall() throws {
        try? runLaunchctl(arguments: ["bootout", guiDomain, plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func runLaunchctl(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }

    private static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    private static var guiDomain: String {
        "gui/\(getuid())"
    }
}

extension Notification.Name {
    static let loopShouldClosePopover = Notification.Name("Loop.shouldClosePopover")
    static let loopPopoverWillClose = Notification.Name("Loop.popoverWillClose")
    static let loopShouldEditTask = Notification.Name("Loop.shouldEditTask")
    static let loopShouldCheckMorningOnboarding = Notification.Name("Loop.shouldCheckMorningOnboarding")
    static let loopFocusModeDidEnd = Notification.Name("Loop.focusModeDidEnd")
    static let loopFocusDidStart = Notification.Name("Loop.focusDidStart")
}
