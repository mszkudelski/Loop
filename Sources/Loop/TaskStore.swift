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

    @Published private(set) var shortcut: KeyboardShortcutSetting = .defaultShortcut
    @Published private(set) var doneShortcut: KeyboardShortcutSetting = .defaultDoneShortcut
    @Published private(set) var quickAddShortcut: KeyboardShortcutSetting = .defaultQuickAddShortcut
    @Published private(set) var breakShortcut: KeyboardShortcutSetting = .defaultBreakShortcut
    @Published private(set) var breakDurationMinutes = 5 {
        didSet { save() }
    }

    @Published private(set) var focusedTaskID: UUID? {
        didSet { save() }
    }

    @Published private(set) var autoOpenFocusedTaskApp = true {
        didSet { save() }
    }

    @Published private(set) var dismissedFastLoopSuggestionAt: Date? {
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

    @Published private(set) var currentDate = Date()

    @Published var notice: String?

    var onShortcutChange: ((KeyboardShortcutSetting) -> Void)?
    var onDoneShortcutChange: ((KeyboardShortcutSetting) -> Void)?
    var onQuickAddShortcutChange: ((KeyboardShortcutSetting) -> Void)?
    var onBreakShortcutChange: ((KeyboardShortcutSetting) -> Void)?

    private let defaultsKey = "Loop.store.v1"
    private let fastLoopCompletionThreshold: TimeInterval = 2 * 60
    private let fastLoopSuggestionWindow: TimeInterval = 10 * 60
    private let quickCompletionThreshold: TimeInterval = 20
    private let quickCompletionSuggestionWindow: TimeInterval = 10 * 60
    private var openingTaskIDs = Set<UUID>()
    private var lastAutoOpenedFocusedTaskID: UUID?
    private var snoozeRefreshTimer: Timer?
    private var countdownRefreshTimer: Timer?
    private var isLoading = false

    init() {
        load()
        startSnoozeRefreshTimer()
        startCountdownRefreshTimer()
    }

    var activeTasks: [LoopTask] {
        orderedForIteration(tasks.filter { !$0.isBacklog && !$0.finished && !$0.doneThisLoop && isDue($0) && !isSnoozed($0) })
    }

    var currentLoopTasks: [LoopTask] {
        orderedForIteration(tasks.filter { !$0.isBacklog && !$0.finished && ($0.doneThisLoop || (isDue($0) && !isSnoozed($0))) })
    }

    var currentFocusTaskID: UUID? {
        guard !isOnBreak else { return nil }
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

        let minutes = max(0, Int(ceil(Double(remainingSeconds) / 60.0)))
        return "\(minutes)m"
    }

    var isOnBreak: Bool {
        breakStartedAt != nil
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

    var doneTasks: [LoopTask] {
        tasks
            .filter { !$0.isBacklog && !$0.finished && $0.doneThisLoop }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var upcomingTasks: [LoopTask] {
        tasks
            .filter { !$0.isBacklog && !$0.finished && !$0.doneThisLoop && (!isDue($0) || isSnoozed($0)) }
            .sorted {
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

    func tasksFinished(on date: Date) -> [LoopTask] {
        finishedTasks.filter { task in
            guard let finishedAt = task.finishedAt else { return false }
            return Calendar.current.isDate(finishedAt, inSameDayAs: date)
        }
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

    var averageLoopsToFinish: Double? {
        averageLoopsToFinish(on: nil)
    }

    func averageLoopsToFinish(on date: Date?) -> Double? {
        let stats = completedTaskStats(on: date)
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
        tasks[index].dismissedSuggestions.append(suggestion)
        tasks[index].updatedAt = Date()
    }

    func dismissFastLoopSuggestion() {
        dismissedFastLoopSuggestionAt = Date()
    }

    func addTask(
        title: String,
        linkedApp: LinkedApp? = nil,
        cadence: LoopCadence = .everyLoop,
        iterationTimerMinutes: Int? = nil,
        addToIteration: Bool = true
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        tasks.append(LoopTask(
            title: trimmedTitle,
            linkedApp: linkedApp,
            cadence: cadence,
            isBacklog: !addToIteration,
            sortOrder: nextSortOrder(),
            createdLoop: addToIteration ? loopNumber : nil,
            iterationTimerMinutes: normalizedIterationTimerMinutes(iterationTimerMinutes)
        ))
        ensureFocusedTask()
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

    func toggleDone(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard !tasks[index].isBacklog else { return }
        if tasks[index].isPriority {
            completePriorityTask(at: index, openNextFocusedApp: true)
            return
        }
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

        return markTaskDone(task, openNextFocusedApp: openNextFocusedApp)
    }

    func finish(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
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
        tasks.removeAll { $0.id == task.id }
        if focusedTaskID == task.id {
            focusedTaskID = nil
        }
        ensureFocusedTask()
    }

    func addToIteration(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return }
        tasks[index].isBacklog = false
        tasks[index].doneThisLoop = false
        tasks[index].lastCompletedLoop = nil
        tasks[index].snoozedUntil = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].createdLoop = tasks[index].createdLoop ?? loopNumber
        tasks[index].updatedAt = Date()
        ensureFocusedTask(openLinkedAppIfChanged: false)
    }

    func moveToBacklog(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return }
        let wasUndoneCurrentLoopTask = currentLoopTasks.contains { $0.id == task.id && !$0.doneThisLoop }
        tasks[index].isBacklog = true
        tasks[index].doneThisLoop = false
        tasks[index].lastCompletedLoop = nil
        tasks[index].snoozedUntil = nil
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = Date()
        if focusedTaskID == task.id {
            focusedTaskID = nil
        }
        if wasUndoneCurrentLoopTask && advanceLoopIfNoUndoneCurrentLoopTasks(openNextFocusedApp: true) {
            return
        }
        ensureFocusedTask()
    }

    func togglePriority(_ task: LoopTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
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
        guard !task.isBacklog else { return }
        guard currentLoopTasks.contains(where: { $0.id == task.id && !$0.doneThisLoop }) else { return }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].manualFocusCount += 1
        }
        setFocusedTaskID(task.id, openLinkedAppIfChanged: true)
    }

    func snooze(_ task: LoopTask, minutes: Int = 30) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id && !$0.finished }) else { return }
        guard !tasks[index].isBacklog else { return }
        let wasDoneThisLoop = tasks[index].doneThisLoop
        tasks[index].snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        tasks[index].snoozeCount += 1
        tasks[index].lastQuickCompletionAt = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        tasks[index].updatedAt = Date()
        if focusedTaskID == task.id {
            focusedTaskID = nil
        }
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
        tasks[index].snoozedUntil = nil
        tasks[index].updatedAt = Date()
        ensureFocusedTask()
    }

    func setAutoOpenFocusedTaskApp(_ isEnabled: Bool) {
        autoOpenFocusedTaskApp = isEnabled
    }

    func setBreakDurationMinutes(_ minutes: Int) {
        let clampedMinutes = min(max(minutes, 1), 120)
        breakDurationMinutes = clampedMinutes
        if isOnBreak, let breakStartedAt {
            breakUntil = breakStartedAt.addingTimeInterval(TimeInterval(clampedMinutes * 60))
        }
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
        applyCurrentLoopTaskOrder(reorderedLoopTasks)
    }

    func advanceLoop() {
        advanceLoop(openNextFocusedApp: false, resetFocusToFirstTask: true)
    }

    private func advanceLoop(openNextFocusedApp: Bool, resetFocusToFirstTask: Bool) {
        loopCompletions.append(LoopCompletion(loopNumber: loopNumber))
        loopNumber += 1
        clearPriorityDeferrals()
        for index in tasks.indices where !tasks[index].isBacklog && !tasks[index].finished && tasks[index].doneThisLoop {
            tasks[index].doneThisLoop = false
            tasks[index].lastQuickCompletionAt = nil
            tasks[index].updatedAt = Date()
        }
        if resetFocusToFirstTask {
            focusedTaskID = nil
        }
        ensureFocusedTask(openLinkedAppIfChanged: openNextFocusedApp)
    }

    private func advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: Bool) -> Bool {
        let currentTasks = currentLoopTasks.filter { !$0.isPriority }
        guard !currentTasks.isEmpty, currentTasks.allSatisfy(\.doneThisLoop) else { return false }
        advanceLoop(openNextFocusedApp: openNextFocusedApp, resetFocusToFirstTask: true)
        return true
    }

    private func advanceLoopIfNoUndoneCurrentLoopTasks(openNextFocusedApp: Bool) -> Bool {
        guard !currentLoopTasks.contains(where: { !$0.isPriority && !$0.doneThisLoop }) else { return false }
        advanceLoop(openNextFocusedApp: openNextFocusedApp, resetFocusToFirstTask: true)
        return true
    }

    func resetCurrentLoop() {
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
        guard let lastCompletedLoop = task.lastCompletedLoop else { return true }
        return loopNumber - lastCompletedLoop >= task.cadence.rawValue
    }

    func isSnoozed(_ task: LoopTask, at date: Date = Date()) -> Bool {
        guard let snoozedUntil = task.snoozedUntil else { return false }
        return snoozedUntil > date
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
        return max(0, Int(ceil(deadline.timeIntervalSince(date ?? currentDate))))
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
        guard !isOnBreak else {
            endBreak()
            return
        }

        let now = Date()
        breakShouldFocusPriorityAfterBreak = completeFocusedTaskForBreak()
        breakStartedAt = now
        breakUntil = now.addingTimeInterval(breakDurationSeconds)
        focusedTaskID = nil
        lastAutoOpenedFocusedTaskID = nil
        currentDate = now
    }

    func endBreak() {
        breakStartedAt = nil
        breakUntil = nil
        currentDate = Date()
        resumeAfterBreak()
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
        return task.cadence != .everyFourLoops
    }

    private func dismissedSuggestion(_ suggestion: LoopTaskSuggestion, for task: LoopTask) -> Bool {
        task.dismissedSuggestions.contains(suggestion)
    }

    private func recordFocusStarted(for taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].focusedAt = Date()
        if !tasks[index].doneThisLoop {
            tasks[index].lastQuickCompletionAt = nil
        }
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
        guard !tasks[index].doneThisLoop, !tasks[index].finished, !tasks[index].isBacklog else { return }
        guard resetExisting || tasks[index].iterationTimerStartedLoop != loopNumber || tasks[index].iterationTimerStartedAt == nil else { return }
        tasks[index].iterationTimerStartedAt = Date()
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

    private func completeFocusedTaskForBreak() -> Bool {
        guard
            let currentFocusTaskID,
            let index = tasks.firstIndex(where: { $0.id == currentFocusTaskID && !$0.finished && !$0.isBacklog && !$0.doneThisLoop })
        else {
            return false
        }

        if tasks[index].isPriority {
            tasks[index].doneThisLoop = false
            tasks[index].lastCompletedLoop = nil
            tasks[index].lastQuickCompletionAt = nil
            tasks[index].snoozedUntil = nil
            tasks[index].iterationTimerStartedAt = nil
            tasks[index].iterationTimerStartedLoop = nil
            tasks[index].priorityDeferredLoop = loopNumber
            tasks[index].updatedAt = Date()
            return false
        }

        tasks[index].doneThisLoop = true
        tasks[index].lastCompletedLoop = loopNumber
        tasks[index].snoozedUntil = nil
        tasks[index].iterationTimerStartedAt = nil
        tasks[index].iterationTimerStartedLoop = nil
        recordQuickCompletionIfNeeded(for: &tasks[index])
        clearPriorityDeferrals()
        tasks[index].updatedAt = Date()
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
        if focusedTaskID == tasks[index].id {
            focusedTaskID = nil
        }
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

        if shouldFocusPriority, focusPriorityAfterRegularTaskCompletion(openNextFocusedApp: true) {
            return
        }

        if advanceLoopIfCurrentLoopIsDone(openNextFocusedApp: true) {
            return
        }

        ensureFocusedTask(openLinkedAppIfChanged: true)
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
        if focusedTaskID != nextFocusedTaskID {
            focusedTaskID = nextFocusedTaskID
        }
        if didFocusChange, let nextFocusedTaskID {
            recordFocusStarted(for: nextFocusedTaskID)
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
        currentDate = Date()
    }

    private func normalizedIterationTimerMinutes(_ minutes: Int?) -> Int? {
        guard let minutes, minutes > 0 else { return nil }
        return min(minutes, 24 * 60)
    }

    private func refreshExpiredSnoozes() {
        let now = Date()
        var didChange = false
        for index in tasks.indices where tasks[index].snoozedUntil.map({ $0 <= now }) == true {
            tasks[index].snoozedUntil = nil
            tasks[index].updatedAt = now
            didChange = true
        }

        if didChange {
            ensureFocusedTask()
        }
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = StoreSnapshot(
            tasks: tasks,
            loopNumber: loopNumber,
            loopCompletions: loopCompletions,
            focusedTaskID: focusedTaskID,
            autoOpenFocusedTaskApp: autoOpenFocusedTaskApp,
            dismissedFastLoopSuggestionAt: dismissedFastLoopSuggestionAt,
            breakStartedAt: breakStartedAt,
            breakUntil: breakUntil,
            breakShouldFocusPriorityAfterBreak: breakShouldFocusPriorityAfterBreak,
            breakDurationMinutes: breakDurationMinutes,
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
            if !isOnBreak {
                ensureFocusedTask()
            }
            save()
        }

        loopNumber = max(1, snapshot.loopNumber)
        loopCompletions = snapshot.loopCompletions
        focusedTaskID = snapshot.focusedTaskID
        autoOpenFocusedTaskApp = snapshot.autoOpenFocusedTaskApp
        dismissedFastLoopSuggestionAt = snapshot.dismissedFastLoopSuggestionAt
        breakStartedAt = snapshot.breakStartedAt
        breakUntil = snapshot.breakUntil
        breakShouldFocusPriorityAfterBreak = snapshot.breakShouldFocusPriorityAfterBreak
        breakDurationMinutes = min(max(snapshot.breakDurationMinutes, 1), 120)
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
        shortcut = snapshot.shortcut.normalized
    }
}

private struct StoreSnapshot: Codable {
    var tasks: [LoopTask]
    var loopNumber: Int
    var loopCompletions: [LoopCompletion]
    var focusedTaskID: UUID?
    var autoOpenFocusedTaskApp: Bool
    var dismissedFastLoopSuggestionAt: Date?
    var breakStartedAt: Date?
    var breakUntil: Date?
    var breakShouldFocusPriorityAfterBreak: Bool
    var breakDurationMinutes: Int
    var shortcut: KeyboardShortcutSetting
    var doneShortcut: KeyboardShortcutSetting
    var quickAddShortcut: KeyboardShortcutSetting
    var breakShortcut: KeyboardShortcutSetting

    private enum CodingKeys: String, CodingKey {
        case tasks
        case loopNumber
        case loopCompletions
        case focusedTaskID
        case autoOpenFocusedTaskApp
        case dismissedFastLoopSuggestionAt
        case breakStartedAt
        case breakUntil
        case breakShouldFocusPriorityAfterBreak
        case breakDurationMinutes
        case shortcut
        case doneShortcut
        case quickAddShortcut
        case breakShortcut
    }

    init(
        tasks: [LoopTask],
        loopNumber: Int,
        loopCompletions: [LoopCompletion],
        focusedTaskID: UUID?,
        autoOpenFocusedTaskApp: Bool,
        dismissedFastLoopSuggestionAt: Date?,
        breakStartedAt: Date?,
        breakUntil: Date?,
        breakShouldFocusPriorityAfterBreak: Bool,
        breakDurationMinutes: Int,
        shortcut: KeyboardShortcutSetting,
        doneShortcut: KeyboardShortcutSetting,
        quickAddShortcut: KeyboardShortcutSetting,
        breakShortcut: KeyboardShortcutSetting
    ) {
        self.tasks = tasks
        self.loopNumber = loopNumber
        self.loopCompletions = loopCompletions
        self.focusedTaskID = focusedTaskID
        self.autoOpenFocusedTaskApp = autoOpenFocusedTaskApp
        self.dismissedFastLoopSuggestionAt = dismissedFastLoopSuggestionAt
        self.breakStartedAt = breakStartedAt
        self.breakUntil = breakUntil
        self.breakShouldFocusPriorityAfterBreak = breakShouldFocusPriorityAfterBreak
        self.breakDurationMinutes = breakDurationMinutes
        self.shortcut = shortcut
        self.doneShortcut = doneShortcut
        self.quickAddShortcut = quickAddShortcut
        self.breakShortcut = breakShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([LoopTask].self, forKey: .tasks) ?? []
        loopNumber = try container.decodeIfPresent(Int.self, forKey: .loopNumber) ?? 1
        loopCompletions = try container.decodeIfPresent([LoopCompletion].self, forKey: .loopCompletions) ?? []
        focusedTaskID = try container.decodeIfPresent(UUID.self, forKey: .focusedTaskID)
        autoOpenFocusedTaskApp = try container.decodeIfPresent(Bool.self, forKey: .autoOpenFocusedTaskApp) ?? true
        dismissedFastLoopSuggestionAt = try container.decodeIfPresent(Date.self, forKey: .dismissedFastLoopSuggestionAt)
        breakStartedAt = try container.decodeIfPresent(Date.self, forKey: .breakStartedAt)
        breakUntil = try container.decodeIfPresent(Date.self, forKey: .breakUntil)
        breakShouldFocusPriorityAfterBreak = try container.decodeIfPresent(Bool.self, forKey: .breakShouldFocusPriorityAfterBreak) ?? false
        breakDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .breakDurationMinutes) ?? 5
        shortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .shortcut) ?? .defaultShortcut
        doneShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .doneShortcut) ?? .defaultDoneShortcut
        quickAddShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .quickAddShortcut) ?? .defaultQuickAddShortcut
        breakShortcut = try container.decodeIfPresent(KeyboardShortcutSetting.self, forKey: .breakShortcut) ?? .defaultBreakShortcut
    }
}

extension Notification.Name {
    static let loopShouldClosePopover = Notification.Name("Loop.shouldClosePopover")
}
