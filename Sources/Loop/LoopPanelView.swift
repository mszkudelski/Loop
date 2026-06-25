import AppKit
import SwiftUI

struct LoopPanelView: View {
    @EnvironmentObject private var store: TaskStore

    let onQuit: () -> Void
    let onChooseApplication: () -> LinkedApp?

    @State private var selectedView: PanelView = .loop
    @State private var newTaskTitle = ""
    @State private var newTaskCadence: LoopCadence = .everyLoop
    @State private var editingTask: LoopTask?
    @State private var isAddingDetailedTask = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(width: 440)
        .frame(minHeight: 560)
        .background(.regularMaterial)
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task, onChooseApplication: onChooseApplication) { updatedTask in
                store.updateTask(updatedTask)
            }
        }
        .sheet(isPresented: $isAddingDetailedTask) {
            TaskEditorView(task: nil, onChooseApplication: onChooseApplication) { newTask in
                store.addTask(
                    title: newTask.title,
                    linkedApp: newTask.linkedApp,
                    cadence: newTask.cadence,
                    iterationTimerMinutes: newTask.iterationTimerMinutes,
                    addToIteration: !newTask.isBacklog
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loop")
                        .font(.title2.weight(.semibold))
                    Text("Iteration \(store.loopNumber)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.advanceLoop()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Next iteration")
            }

            HStack(alignment: .center, spacing: 10) {
                Picker("", selection: $selectedView) {
                    ForEach(PanelView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    @ViewBuilder
    private var content: some View {
        switch selectedView {
        case .loop:
            LoopTasksView(editingTask: $editingTask) {
                isAddingDetailedTask = true
            }
        case .tasks:
            AllTasksView(editingTask: $editingTask)
        case .backlog:
            BacklogTasksView(editingTask: $editingTask)
        case .stats:
            StatisticsView()
        case .shortcut:
            ShortcutSettingsView()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let notice = store.notice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(notice)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        store.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("New task", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addQuickTask)

                Picker("Cadence", selection: $newTaskCadence) {
                    ForEach(LoopCadence.allCases) { cadence in
                        Text(cadence.compactTitle).tag(cadence)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 104)

                Button(action: addQuickTask) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Add task")

                Button(action: addQuickBacklogTask) {
                    Image(systemName: "tray.and.arrow.down")
                }
                .help("Add to backlog")

                Button {
                    isAddingDetailedTask = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Add with app")

                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .help("Quit")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    private func addQuickTask() {
        store.addTask(title: newTaskTitle, cadence: newTaskCadence)
        newTaskTitle = ""
    }

    private func addQuickBacklogTask() {
        store.addTask(title: newTaskTitle, cadence: newTaskCadence, addToIteration: false)
        newTaskTitle = ""
    }
}

private enum PanelView: String, CaseIterable, Identifiable {
    case loop
    case tasks
    case backlog
    case stats
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: "Now"
        case .tasks: "Tasks"
        case .backlog: "Backlog"
        case .stats: "Stats"
        case .shortcut: "Shortcut"
        }
    }
}

private struct LoopTasksView: View {
    @EnvironmentObject private var store: TaskStore
    @Binding var editingTask: LoopTask?
    @State private var draggingTaskID: UUID?
    @State private var lastDropTargetID: UUID?
    let onAddTask: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if store.shouldSuggestAddingTaskToFastLoop {
                    LoopSuggestionRow(
                        message: "You are moving through a short loop quickly. Add another task?",
                        actionTitle: "Add task",
                        systemImage: "plus.circle",
                        action: onAddTask
                    )
                }

                TaskSection(title: "Current Iteration", tasks: store.currentLoopTasks, emptyTitle: "No tasks") { task in
                    TaskRow(task: task) {
                        editingTask = task
                    }
                    .opacity(draggingTaskID == task.id ? 0.45 : 1)
                    .onDrag {
                        draggingTaskID = task.id
                        return NSItemProvider(object: task.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: LoopTaskDropDelegate(
                            targetTask: task,
                            draggingTaskID: $draggingTaskID,
                            lastDropTargetID: $lastDropTargetID,
                            store: store
                        )
                    )
                }
            }
            .padding(16)
        }
    }
}

private struct LoopSuggestionRow: View {
    let message: String
    let actionTitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)

            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: action) {
                Label(actionTitle, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AllTasksView: View {
    @EnvironmentObject private var store: TaskStore
    @Binding var editingTask: LoopTask?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                TaskSection(title: "Open", tasks: store.activeTasks, emptyTitle: "No open tasks") { task in
                    TaskRow(task: task) {
                        editingTask = task
                    }
                }

                TaskSection(title: "Later", tasks: store.upcomingTasks, emptyTitle: "No waiting tasks") { task in
                    TaskRow(task: task) {
                        editingTask = task
                    }
                }

                TaskSection(title: "Done This Iteration", tasks: store.doneTasks, emptyTitle: "No done tasks") { task in
                    TaskRow(task: task) {
                        editingTask = task
                    }
                }

                TaskSection(title: "Finished", tasks: store.finishedTasks, emptyTitle: "No finished tasks") { task in
                    FinishedTaskRow(task: task)
                }

                Button {
                    store.resetCurrentLoop()
                } label: {
                    Label("Reset Iteration", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)
        }
    }
}

private struct BacklogTasksView: View {
    @EnvironmentObject private var store: TaskStore
    @Binding var editingTask: LoopTask?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                TaskSection(title: "Backlog", tasks: store.backlogTasks, emptyTitle: "No backlog tasks") { task in
                    TaskRow(task: task) {
                        editingTask = task
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct TaskSection<Item: Identifiable, Content: View>: View {
    let title: String
    let tasks: [Item]
    let emptyTitle: String
    @ViewBuilder let row: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(tasks.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())
            }

            if tasks.isEmpty {
                Text(emptyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ForEach(tasks) { task in
                    row(task)
                }
            }
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let onEdit: () -> Void

    var body: some View {
        let isFocused = store.currentFocusTaskID == task.id
        let isSnoozed = store.isSnoozed(task)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    store.toggleDone(task)
                } label: {
                    Image(systemName: task.isBacklog ? "tray" : (task.doneThisLoop ? "checkmark.circle.fill" : "circle"))
                        .font(.title3)
                        .foregroundStyle(task.doneThisLoop ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(task.isBacklog)
                .help(task.isBacklog ? "Backlog" : (task.doneThisLoop ? "Reopen" : "Done"))

                Button {
                    if task.linkedApp == nil {
                        onEdit()
                    } else {
                        store.openLinkedApp(for: task)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(task.title)
                                .font(.body.weight(isFocused ? .semibold : .medium))
                                .foregroundStyle(task.doneThisLoop ? .secondary : .primary)
                                .strikethrough(task.doneThisLoop, color: .secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if task.isPriority {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                    .help("Priority")
                            }
                        }

                        HStack(spacing: 8) {
                            CadenceBadge(cadence: task.cadence)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let iterationTimerMinutes = task.iterationTimerMinutes {
                                TimerBadge(
                                    minutes: iterationTimerMinutes,
                                    remainingSeconds: isFocused ? store.iterationTimerRemainingSeconds(for: task) : nil
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            if let appName = task.linkedApp?.name {
                                Label(appName, systemImage: "app")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isFocused ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
            .contextMenu {
                if task.isBacklog {
                    Button {
                        store.addToIteration(task)
                    } label: {
                        Label("Add to Iteration", systemImage: "arrow.up.circle")
                    }
                }

                if !task.isBacklog && !task.doneThisLoop && !isSnoozed {
                    Button {
                        store.focus(task)
                    } label: {
                        Label("Focus", systemImage: "scope")
                    }
                    .disabled(isFocused)

                    Divider()
                }

                if !task.isBacklog && isSnoozed {
                    Button {
                        store.unsnooze(task)
                    } label: {
                        Label("Unsnooze", systemImage: "clock.arrow.circlepath")
                    }
                } else if !task.isBacklog {
                    Button {
                        store.snooze(task, minutes: 30)
                    } label: {
                        if task.doneThisLoop {
                            Label("Snooze Next Iterations", systemImage: "clock")
                        } else {
                            Label("Snooze 30 minutes", systemImage: "clock")
                        }
                    }
                }

                Divider()

                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    store.togglePriority(task)
                } label: {
                    Label(
                        task.isPriority ? "Remove Priority" : "Mark Priority",
                        systemImage: task.isPriority ? "star.slash" : "star"
                    )
                }

                if !task.isBacklog {
                    Button {
                        store.moveToBacklog(task)
                    } label: {
                        Label("Move to Backlog", systemImage: "tray.and.arrow.down")
                    }
                }

                Button {
                    store.finish(task)
                } label: {
                    Label("Finish", systemImage: "checkmark.seal")
                }

                Button {
                    store.delete(task)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            if let suggestion = store.suggestion(for: task) {
                LoopSuggestionRow(
                    message: suggestion.message,
                    actionTitle: suggestion.actionTitle,
                    systemImage: suggestion.systemImage
                ) {
                    perform(suggestion)
                }
            }
        }
    }

    private func perform(_ suggestion: LoopTaskSuggestion) {
        switch suggestion {
        case .editCadence:
            onEdit()
        case .markPriority:
            store.togglePriority(task)
        case .snoozeAfterQuickDone:
            store.snooze(task, minutes: 30)
        }
    }
}

private struct CadenceBadge: View {
    let cadence: LoopCadence

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "repeat")
            if cadence.rawValue > 1 {
                Text("\(cadence.rawValue)")
                    .monospacedDigit()
            }
        }
    }
}

private struct TimerBadge: View {
    let minutes: Int
    let remainingSeconds: Int?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "timer")
            Text(timerText)
                .monospacedDigit()
        }
    }

    private var timerText: String {
        guard let remainingSeconds else { return "\(minutes)m" }
        let remainingMinutes = max(0, Int(ceil(Double(remainingSeconds) / 60.0)))
        return "\(remainingMinutes)m"
    }
}

private struct LoopTaskDropDelegate: DropDelegate {
    let targetTask: LoopTask
    @Binding var draggingTaskID: UUID?
    @Binding var lastDropTargetID: UUID?
    let store: TaskStore

    func dropEntered(info: DropInfo) {
        guard
            let draggingTaskID,
            draggingTaskID != targetTask.id,
            lastDropTargetID != targetTask.id
        else {
            return
        }
        lastDropTargetID = targetTask.id
        Task { @MainActor in
            store.moveCurrentLoopTask(draggedTaskID: draggingTaskID, to: targetTask.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        Task { @MainActor in
            draggingTaskID = nil
            lastDropTargetID = nil
        }
        return true
    }
}

private struct FinishedTaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if task.isPriority {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .help("Priority")
                }

                CadenceBadge(cadence: task.cadence)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let appName = task.linkedApp?.name {
                    Text(appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 92, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button {
                store.restore(task)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.left")
            }

            Button {
                store.delete(task)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct StatisticsView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var selectedDate = Date()
    @State private var scope: StatisticsScope = .day

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $scope) {
                    ForEach(StatisticsScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                if scope == .day {
                    dateControls
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    StatTile(title: "Iterations", value: "\(iterationsCount)", systemImage: "arrow.triangle.2.circlepath")
                    StatTile(title: "Finished", value: "\(finishedCount)", systemImage: "checkmark.seal")
                    StatTile(
                        title: "Avg Iterations / Task",
                        value: averageText,
                        systemImage: "chart.bar"
                    )
                    StatTile(
                        title: scope == .day ? "All-Time Finished" : "Days Active",
                        value: "\(referenceCount)",
                        systemImage: "list.bullet"
                    )
                }

                TaskSection(title: "Finished Tasks", tasks: finishedStats, emptyTitle: "No finished tasks") { stat in
                    CompletedTaskStatRow(stat: stat)
                }
            }
            .padding(16)
        }
    }

    private var dateControls: some View {
        HStack(spacing: 8) {
            Button {
                moveSelectedDate(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous day")

            Text(dayTitle)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)

            Button {
                moveSelectedDate(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(isSelectedDateToday)
            .help("Next day")

            Button("Today") {
                selectedDate = Date()
            }
            .disabled(isSelectedDateToday)
            .controlSize(.small)
        }
    }

    private var iterationsCount: Int {
        switch scope {
        case .day: store.loopsCompleted(on: selectedDate)
        case .total: store.loopsCompletedTotal
        }
    }

    private var finishedCount: Int {
        switch scope {
        case .day: store.tasksFinished(on: selectedDate).count
        case .total: store.completedTaskStats.count
        }
    }

    private var finishedStats: [TaskCompletionStat] {
        switch scope {
        case .day: store.completedTaskStats(on: selectedDate)
        case .total: store.completedTaskStats
        }
    }

    private var referenceCount: Int {
        switch scope {
        case .day: store.completedTaskStats.count
        case .total: store.daysActiveTotal
        }
    }

    private var averageText: String {
        let average = scope == .day
            ? store.averageLoopsToFinish(on: selectedDate)
            : store.averageLoopsToFinish
        guard let average else { return "-" }
        return String(format: "%.1f", average)
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(selectedDate) {
            return "Yesterday"
        }
        return StatisticsDateFormatter.day.string(from: selectedDate)
    }

    private var isSelectedDateToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private func moveSelectedDate(by days: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }
}

private enum StatisticsScope: String, CaseIterable, Identifiable {
    case day
    case total

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .total: "Total"
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CompletedTaskStatRow: View {
    let stat: TaskCompletionStat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(stat.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(StatisticsDateFormatter.shortDateTime.string(from: stat.finishedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(stat.loopsTaken) \(stat.loopsTaken == 1 ? "iteration" : "iterations")")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum StatisticsDateFormatter {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: LoopTask

    private let isNew: Bool
    let onChooseApplication: () -> LinkedApp?
    let onSave: (LoopTask) -> Void

    init(task: LoopTask?, onChooseApplication: @escaping () -> LinkedApp?, onSave: @escaping (LoopTask) -> Void) {
        _draft = State(initialValue: task ?? LoopTask(title: ""))
        self.isNew = task == nil
        self.onChooseApplication = onChooseApplication
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Task" : "Edit Task")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Task name", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Application")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: popularApplicationColumns, spacing: 6) {
                    ForEach(PopularApplication.allCases) { app in
                        Button {
                            draft.linkedApp = app.linkedApp
                        } label: {
                            Text(app.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Text(draft.linkedApp?.name ?? "No app selected")
                        .lineLimit(1)
                    Spacer()
                    Button("Choose") {
                        chooseApplication()
                    }
                    if draft.linkedApp != nil {
                        Button {
                            draft.linkedApp = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Cadence")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Cadence", selection: $draft.cadence) {
                    ForEach(LoopCadence.allCases) { cadence in
                        Text(cadence.compactTitle).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Iteration timer", isOn: iterationTimerEnabledBinding)
                    .toggleStyle(.checkbox)

                if draft.iterationTimerMinutes != nil {
                    Stepper(value: iterationTimerMinutesBinding, in: 1...240, step: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .foregroundStyle(.secondary)
                            Text("\(draft.iterationTimerMinutes ?? 10) minutes")
                                .monospacedDigit()
                        }
                    }
                }
            }

            Toggle("Backlog", isOn: $draft.isBacklog)
                .toggleStyle(.checkbox)

            if !isNew {
                if !draft.isBacklog {
                    Toggle("Done this iteration", isOn: $draft.doneThisLoop)
                        .toggleStyle(.checkbox)
                }

                Toggle("Finished", isOn: $draft.finished)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func chooseApplication() {
        if let linkedApp = onChooseApplication() {
            draft.linkedApp = linkedApp
        }
    }

    private var iterationTimerEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                draft.iterationTimerMinutes != nil
            },
            set: { isEnabled in
                if isEnabled {
                    draft.iterationTimerMinutes = draft.iterationTimerMinutes ?? 10
                } else {
                    draft.iterationTimerMinutes = nil
                }
                draft.iterationTimerStartedAt = nil
                draft.iterationTimerStartedLoop = nil
            }
        )
    }

    private var iterationTimerMinutesBinding: Binding<Int> {
        Binding(
            get: {
                draft.iterationTimerMinutes ?? 10
            },
            set: { minutes in
                draft.iterationTimerMinutes = min(max(minutes, 1), 240)
                draft.iterationTimerStartedAt = nil
                draft.iterationTimerStartedLoop = nil
            }
        )
    }

    private var popularApplicationColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
    }
}

private enum PopularApplication: String, CaseIterable, Identifiable {
    case codex
    case githubCopilot
    case visualStudioCode
    case slack
    case safari

    var id: String { rawValue }

    var title: String {
        linkedApp.name
    }

    var linkedApp: LinkedApp {
        switch self {
        case .codex:
            LinkedApp(
                name: "Codex",
                bundleIdentifier: "com.openai.chat",
                path: "/Applications/Codex.app"
            )
        case .githubCopilot:
            LinkedApp(
                name: "GitHub Copilot",
                bundleIdentifier: "com.github.Copilot",
                path: "/Applications/GitHub Copilot.app"
            )
        case .visualStudioCode:
            LinkedApp(
                name: "VS Code",
                bundleIdentifier: "com.microsoft.VSCode",
                path: "/Applications/Visual Studio Code.app"
            )
        case .slack:
            LinkedApp(
                name: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                path: "/Applications/Slack.app"
            )
        case .safari:
            LinkedApp(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                path: "/Applications/Safari.app"
            )
        }
    }
}

private struct ShortcutSettingsView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shortcuts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                shortcutRecorder(
                    title: "Open panel",
                    shortcut: store.shortcut,
                    onRecord: store.applyShortcut
                )

                shortcutRecorder(
                    title: "Done focused task",
                    shortcut: store.doneShortcut,
                    onRecord: store.applyDoneShortcut
                )

                shortcutRecorder(
                    title: "Quick add to backlog",
                    shortcut: store.quickAddShortcut,
                    onRecord: store.applyQuickAddShortcut
                )

                Divider()

                Toggle("Auto-open focused app", isOn: Binding(
                    get: {
                        store.autoOpenFocusedTaskApp
                    },
                    set: { isEnabled in
                        store.setAutoOpenFocusedTaskApp(isEnabled)
                    }
                ))
                .toggleStyle(.checkbox)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func shortcutRecorder(
        title: String,
        shortcut: KeyboardShortcutSetting,
        onRecord: @escaping (KeyboardShortcutSetting) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))

            ShortcutRecorderView(shortcut: shortcut, onRecord: onRecord)
                .frame(width: 210, height: 32)
        }
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    let shortcut: KeyboardShortcutSetting
    let onRecord: (KeyboardShortcutSetting) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let control = ShortcutRecorderControl()
        control.onRecord = onRecord
        return control
    }

    func updateNSView(_ nsView: ShortcutRecorderControl, context: Context) {
        nsView.shortcut = shortcut
        nsView.onRecord = onRecord
    }
}

private final class ShortcutRecorderControl: NSView {
    var shortcut: KeyboardShortcutSetting = .defaultShortcut {
        didSet {
            needsDisplay = true
            setAccessibilityValue(shortcut.displayText)
        }
    }
    var onRecord: ((KeyboardShortcutSetting) -> Void)?
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record shortcut")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            isRecording = false
            return
        }

        guard let key = ShortcutKeyMap.key(for: event.keyCode) else {
            return
        }

        let modifiers = ShortcutModifier.from(event.modifierFlags)
        guard !modifiers.isEmpty else {
            return
        }

        isRecording = false
        onRecord?(KeyboardShortcutSetting(key: key, modifiers: modifiers))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = 6
        let fill = NSColor.controlBackgroundColor
        let stroke = isRecording ? NSColor.controlAccentColor : NSColor.separatorColor
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording ? "Press shortcut..." : shortcut.displayText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedText.size()
        let textRect = NSRect(
            x: bounds.minX + 10,
            y: bounds.midY - textSize.height / 2,
            width: max(0, bounds.width - 20),
            height: textSize.height
        )
        attributedText.draw(in: textRect)
    }
}

private extension ShortcutModifier {
    static func from(_ flags: NSEvent.ModifierFlags) -> Set<ShortcutModifier> {
        let activeFlags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<ShortcutModifier>()
        if activeFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if activeFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if activeFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if activeFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        return modifiers
    }
}

private enum ShortcutKeyMap {
    private static let keys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`"
    ]

    static func key(for keyCode: UInt16) -> String? {
        keys[keyCode]
    }
}
