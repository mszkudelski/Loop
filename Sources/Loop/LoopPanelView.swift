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
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420)
        .frame(minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
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
                    addToIteration: !newTask.isBacklog
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Iteration \(store.loopNumber)")
                .font(.title3.weight(.semibold))

            HStack(alignment: .center, spacing: 10) {
                Picker("", selection: $selectedView) {
                    ForEach(PanelView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    store.advanceLoop()
                } label: {
                    Label("Next", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
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
        .padding(12)
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
            .padding(12)
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
            .padding(12)
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
            .padding(12)
        }
    }
}

private struct TaskSection<Item: Identifiable, Content: View>: View {
    let title: String
    let tasks: [Item]
    let emptyTitle: String
    @ViewBuilder let row: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if tasks.isEmpty {
                Text(emptyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
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

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    store.toggleDone(task)
                } label: {
                    Image(systemName: task.isBacklog ? "tray" : (task.doneThisLoop ? "checkmark.circle.fill" : "circle"))
                        .font(.body)
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
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.body.weight(.medium))
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
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isFocused ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
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

    @State private var openKey = KeyboardShortcutSetting.defaultShortcut.key
    @State private var openModifiers = KeyboardShortcutSetting.defaultShortcut.modifiers
    @State private var doneKey = KeyboardShortcutSetting.defaultDoneShortcut.key
    @State private var doneModifiers = KeyboardShortcutSetting.defaultDoneShortcut.modifiers

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            shortcutEditor(
                title: "Open panel",
                currentText: store.shortcut.displayText,
                key: $openKey,
                modifiers: $openModifiers,
                defaultShortcut: .defaultShortcut
            ) {
                store.applyShortcut(KeyboardShortcutSetting(key: openKey, modifiers: openModifiers))
            }

            shortcutEditor(
                title: "Done focused task",
                currentText: store.doneShortcut.displayText,
                key: $doneKey,
                modifiers: $doneModifiers,
                defaultShortcut: .defaultDoneShortcut
            ) {
                store.applyDoneShortcut(KeyboardShortcutSetting(key: doneKey, modifiers: doneModifiers))
            }

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

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            openKey = store.shortcut.key
            openModifiers = store.shortcut.modifiers
            doneKey = store.doneShortcut.key
            doneModifiers = store.doneShortcut.modifiers
        }
    }

    @ViewBuilder
    private func shortcutEditor(
        title: String,
        currentText: String,
        key: Binding<String>,
        modifiers: Binding<Set<ShortcutModifier>>,
        defaultShortcut: KeyboardShortcutSetting,
        onApply: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        Toggle(modifier.title, isOn: binding(for: modifier, modifiers: modifiers))
                            .toggleStyle(.checkbox)
                    }
                }

                HStack(spacing: 10) {
                    TextField("Key", text: key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: key.wrappedValue) { newValue in
                            key.wrappedValue = String(newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(1))
                        }

                    Button("Apply") {
                        onApply()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!KeyboardShortcutSetting(key: key.wrappedValue, modifiers: modifiers.wrappedValue).isValid)
                }

                Text(currentText.isEmpty ? defaultShortcut.displayText : currentText)
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func binding(for modifier: ShortcutModifier, modifiers: Binding<Set<ShortcutModifier>>) -> Binding<Bool> {
        Binding(
            get: {
                modifiers.wrappedValue.contains(modifier)
            },
            set: { isEnabled in
                if isEnabled {
                    modifiers.wrappedValue.insert(modifier)
                } else {
                    modifiers.wrappedValue.remove(modifier)
                }
            }
        )
    }
}
