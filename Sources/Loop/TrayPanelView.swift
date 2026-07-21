import SwiftUI

struct TrayPanelView: View {
    @EnvironmentObject private var store: TaskStore

    let onPrimaryAction: () -> Void
    let onSelectTask: (LoopTask) -> Void
    let onEditTask: (LoopTask) -> Void
    let onSelectRoutine: (RoutineBlock) -> Void
    let onEditRoutine: (RoutineBlock) -> Void
    let onOpenTaskManager: () -> Void
    let onOpenMorningPlan: () -> Void
    let onOpenSettings: () -> Void
    let onOpenStats: () -> Void

    @State private var quickTaskTitle = ""
    @State private var renamingTask: LoopTask?
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Loop")
                            .font(.headline)
                        Text("Iteration \(store.loopNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    trayIconButton(
                        systemImage: "macwindow",
                        help: "Open Task Manager",
                        action: onOpenTaskManager
                    )

                    trayIconButton(
                        systemImage: "chart.bar",
                        help: "Open Stats",
                        action: onOpenStats
                    )

                    trayIconButton(
                        systemImage: "gearshape",
                        help: "Open Settings",
                        action: onOpenSettings
                    )
                }

                HStack(spacing: 6) {
                    productivityBadge
                    lastIterationBadge
                    Spacer()
                }
            }

            statusCard

            if shouldOpenMorningPlan {
                Button(action: onOpenMorningPlan) {
                    Label("Open Morning Plan", systemImage: "sun.max.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if !store.isInMeeting {
                HStack(spacing: 8) {
                    if store.isFocusTimeActive, !store.isOnBreak, !store.isInRoutine {
                        Button {
                            store.endFocusTimeForToday()
                        } label: {
                            Label("End focus today", systemImage: "stop.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .help("Resume automatically at the next scheduled focus block")
                    }

                    Button(action: onPrimaryAction) {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(primaryActionIsDisabled)
                    .help(primaryActionIsDisabled ? "Breaks are disabled during focus time" : primaryActionTitle)
                }
            }

            iterationQueue

            Divider()

            quickTaskInput
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial)
        .alert("Rename Task", isPresented: isRenamingTask) {
            TextField("Task name", text: $renameDraft)

            Button("Cancel", role: .cancel) {
                renamingTask = nil
            }

            Button("Save") {
                guard let renamingTask else { return }
                store.updateTaskTitle(renamingTask, title: renameDraft)
                self.renamingTask = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a new name for this task.")
        }
    }

    private var productivityBadge: some View {
        Label("\(productivityPercentage)%", systemImage: "bolt.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(nsColor: .systemGreen))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .systemGreen).opacity(0.12), in: Capsule())
            .help("Productivity today")
    }

    private var lastIterationBadge: some View {
        Label(lastIterationDurationText, systemImage: "timer")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .help("Last iteration time")
    }

    private var lastIterationDurationText: String {
        guard let duration = store.previousIterationDuration(on: store.currentDate) else { return "–" }
        return IterationDurationFormatter.string(from: duration)
    }

    private func trayIconButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var quickTaskInput: some View {
        HStack(spacing: 7) {
            TextField("Quick task", text: $quickTaskTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addQuickTask)

            Button(action: addQuickTask) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .disabled(quickTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add task to this iteration")
        }
    }

    private func addQuickTask() {
        store.addTask(title: quickTaskTitle)
        quickTaskTitle = ""
    }

    private var iterationQueue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Iteration", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(openItems.count) open")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if openItems.isEmpty {
                Text(store.isMorningRoutineRequired ? "Complete Morning Plan to begin" : "All tasks are done")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(openItems) { item in
                            switch item {
                            case .task(let task):
                                TrayTaskRow(
                                    task: task,
                                    isCurrent: task.id == currentTask?.id,
                                    onSelect: onSelectTask,
                                    onRename: beginRename,
                                    onEdit: onEditTask
                                )
                            case .routine(let routine):
                                TrayRoutineRow(
                                    routine: routine,
                                    isCurrent: routine.id == store.activeRoutineBlockID,
                                    onSelect: onSelectRoutine,
                                    onEdit: onEditRoutine
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusEyebrow)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(statusTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)

                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let currentTask {
                Button {
                    store.toggleDone(currentTask)
                } label: {
                    Image(systemName: "square")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Mark \(currentTask.title) done")
            } else if let activeRoutine = store.activeRoutineBlock {
                Button {
                    store.endRoutineBlock(markComplete: true)
                } label: {
                    Image(systemName: "square")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Complete \(activeRoutine.title)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            if let currentTask {
                TrayTaskContextMenu(
                    task: currentTask,
                    isCurrent: true,
                    onSelect: onSelectTask,
                    onRename: beginRename,
                    onEdit: onEditTask
                )
            } else if let activeRoutine = store.activeRoutineBlock {
                TrayRoutineContextMenu(
                    routine: activeRoutine,
                    isCurrent: true,
                    onSelect: onSelectRoutine,
                    onEdit: onEditRoutine
                )
            }
        }
    }

    private var statusTitle: String {
        if store.isInMeeting {
            return "In a meeting"
        }
        if let routine = store.activeRoutineBlock {
            return routine.title
        }
        if let currentTask {
            return currentTask.title
        }
        if store.isOnBreak {
            return "On a break"
        }
        if store.isMorningRoutineRequired {
            return "Complete Morning Plan"
        }
        return "No current task"
    }

    private var statusEyebrow: String {
        if store.isInMeeting {
            return "Current status"
        }
        if store.isInRoutine {
            return "Current routine"
        }
        if shouldOpenMorningPlan {
            return "Next step"
        }
        return "Current task"
    }

    private var statusSubtitle: String {
        if let meetingTimerText = store.meetingTimerText {
            return meetingTimerText
        }
        if let breakTimerText = store.breakTimerText {
            return breakTimerText
        }
        if let routineTimerText = store.routineTimerText {
            return routineTimerText
        }
        if shouldOpenMorningPlan {
            return "Plan the iteration before focusing a task"
        }
        if
            let currentTask,
            let remainingSeconds = store.iterationTimerRemainingSeconds(for: currentTask),
            remainingSeconds <= 0
        {
            return "Timer expired"
        }
        if let focusedTaskTimerText = store.focusedTaskTimerText {
            return "\(focusedTaskTimerText) remaining"
        }
        if currentTask != nil {
            if store.isFocusTimeActive {
                return store.focusTimeSchedule.includesRoutines
                    ? "Focus time · Routines included"
                    : "Focus time · Productive tasks only"
            }
            return "Current focus"
        }
        if store.isFocusTimeActive {
            return "Focus time · Add a productive task"
        }
        return "Open Loop to plan your next task"
    }

    private var statusIcon: String {
        if store.isInMeeting {
            return "video.fill"
        }
        if store.isOnBreak {
            return "cup.and.saucer.fill"
        }
        if store.isInRoutine {
            return "clock.fill"
        }
        if shouldOpenMorningPlan {
            return "sun.max.fill"
        }
        if store.focusedTask != nil {
            return "scope"
        }
        return "circle.dashed"
    }

    private var statusColor: Color {
        if store.isOnBreak {
            return Color(nsColor: .systemGreen)
        }
        if store.isInMeeting {
            return Color(nsColor: .systemOrange)
        }
        if shouldOpenMorningPlan {
            return Color(nsColor: .systemYellow)
        }
        return .accentColor
    }

    private var shouldOpenMorningPlan: Bool {
        store.isMorningRoutineRequired
            && !store.isOnBreak
            && !store.isInMeeting
            && !store.isInRoutine
    }

    private var primaryActionTitle: String {
        if store.isOnBreak {
            return "End break"
        }
        if store.isInRoutine {
            return "Start break"
        }
        return "Start break"
    }

    private var primaryActionIcon: String {
        if store.isOnBreak {
            return "play.fill"
        }
        if store.isInRoutine {
            return "cup.and.saucer"
        }
        return "cup.and.saucer"
    }

    private var primaryActionIsDisabled: Bool {
        !store.isOnBreak
            && store.isFocusTimeActive
            && !store.focusTimeSchedule.allowsBreaks
    }

    private var currentTask: LoopTask? {
        store.focusedTask
    }

    private var openTasks: [LoopTask] {
        store.currentLoopTasks.filter { !$0.doneThisLoop && !$0.finished }
    }

    private var openItems: [TrayIterationItem] {
        openTasks.map(TrayIterationItem.task)
            + store.openRoutineBlocks.map(TrayIterationItem.routine)
    }

    private var productivityPercentage: Int {
        let trackedDuration = store.activeDuration(on: store.currentDate)
            + store.routineDuration(on: store.currentDate)
            + store.meetingDuration(on: store.currentDate)
            + store.breakDuration(on: store.currentDate)
        guard trackedDuration > 0 else { return 0 }
        let ratio = store.productiveDuration(on: store.currentDate) / trackedDuration
        return Int(round(min(max(ratio, 0), 1) * 100))
    }

    private var isRenamingTask: Binding<Bool> {
        Binding(
            get: { renamingTask != nil },
            set: { isPresented in
                if !isPresented {
                    renamingTask = nil
                }
            }
        )
    }

    private func beginRename(_ task: LoopTask) {
        renameDraft = task.title
        renamingTask = task
    }

}

private enum TrayIterationItem: Identifiable {
    case task(LoopTask)
    case routine(RoutineBlock)

    var id: String {
        switch self {
        case .task(let task):
            return "task-\(task.id.uuidString)"
        case .routine(let routine):
            return "routine-\(routine.id.uuidString)"
        }
    }
}

private struct TrayRoutineRow: View {
    @EnvironmentObject private var store: TaskStore

    let routine: RoutineBlock
    let isCurrent: Bool
    let onSelect: (RoutineBlock) -> Void
    let onEdit: (RoutineBlock) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isCurrent {
                    store.endRoutineBlock(markComplete: true)
                } else {
                    onSelect(routine)
                }
            } label: {
                Image(systemName: "square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isCurrent ? "Complete \(routine.title)" : "Start \(routine.title)")

            Button {
                if !isCurrent {
                    onSelect(routine)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCurrent ? "scope" : "circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                        .frame(width: 18, height: 18)

                    Text(routine.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: "clock.badge.checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .systemTeal))
                        .help("Routine · \(routine.durationMinutes)m")

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                TrayRoutineContextMenu(
                    routine: routine,
                    isCurrent: isCurrent,
                    onSelect: onSelect,
                    onEdit: onEdit
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Routine actions")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent
                ? Color.accentColor.opacity(0.12)
                : Color(nsColor: .controlBackgroundColor).opacity(0.55)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(isCurrent ? routine.title : "Start \(routine.title)")
        .contextMenu {
            TrayRoutineContextMenu(
                routine: routine,
                isCurrent: isCurrent,
                onSelect: onSelect,
                onEdit: onEdit
            )
        }
    }
}

private struct TrayRoutineContextMenu: View {
    @EnvironmentObject private var store: TaskStore

    let routine: RoutineBlock
    let isCurrent: Bool
    let onSelect: (RoutineBlock) -> Void
    let onEdit: (RoutineBlock) -> Void

    var body: some View {
        Button {
            if isCurrent {
                store.endRoutineBlock(markComplete: true)
            } else {
                onSelect(routine)
            }
        } label: {
            Label(
                isCurrent ? "Complete Routine" : "Start Routine",
                systemImage: isCurrent ? "checkmark" : "play"
            )
        }

        if let linkedApp = routine.linkedApp {
            Button {
                store.openLinkedApp(for: routine)
            } label: {
                Label("Open \(linkedApp.name)", systemImage: "arrow.up.forward.app")
            }
        }

        if isCurrent {
            Button {
                store.endRoutineBlock(markComplete: false)
            } label: {
                Label("Skip Routine", systemImage: "forward.end")
            }
        }

        Button {
            store.snoozeRoutine(routine, minutes: 30)
        } label: {
            Label("Snooze 30 Minutes", systemImage: "clock")
        }

        Menu {
            ForEach(SnoozePreset.secondaryOptions) { preset in
                Button {
                    store.snoozeRoutine(routine, minutes: preset.minutes)
                } label: {
                    Label(preset.title, systemImage: preset.systemImage)
                }
            }
        } label: {
            Label("Snooze for…", systemImage: "clock.badge.questionmark")
        }

        Divider()

        TrayRoutineCadenceMenu(routine: routine)

        Button {
            onEdit(routine)
        } label: {
            Label("Edit Details", systemImage: "slider.horizontal.3")
        }

        Button {
            store.setRoutineEnabled(routine, isEnabled: !routine.isEnabled)
        } label: {
            Label(
                routine.isEnabled ? "Disable Routine" : "Enable Routine",
                systemImage: routine.isEnabled ? "clock.badge.xmark" : "clock.badge.checkmark"
            )
        }

        Divider()

        Button(role: .destructive) {
            store.deleteRoutineBlock(routine)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct TrayRoutineCadenceMenu: View {
    @EnvironmentObject private var store: TaskStore

    let routine: RoutineBlock

    private let quickCadences = [1, 2, 3, 4, 5, 7, 10, 14]

    var body: some View {
        Menu {
            ForEach(quickCadences, id: \.self) { value in
                Button {
                    store.updateRoutineCadence(routine, to: LoopCadence(rawValue: value))
                } label: {
                    Label(
                        LoopCadence(rawValue: value).title,
                        systemImage: routine.cadence.rawValue == value ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            Label("Cadence: \(routine.cadence.title)", systemImage: "arrow.triangle.2.circlepath")
        }
    }
}

private struct TrayTaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let isCurrent: Bool
    let onSelect: (LoopTask) -> Void
    let onRename: (LoopTask) -> Void
    let onEdit: (LoopTask) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.toggleDone(task)
            } label: {
                Image(systemName: "square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Mark \(task.title) done")

            Button {
                onSelect(task)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCurrent ? "scope" : "circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                        .frame(width: 18, height: 18)

                    Text(task.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if task.isPriority {
                        Image(systemName: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent
                ? Color.accentColor.opacity(0.12)
                : Color(nsColor: .controlBackgroundColor).opacity(0.55)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("Focus \(task.title)")
        .contextMenu {
            TrayTaskContextMenu(
                task: task,
                isCurrent: isCurrent,
                onSelect: onSelect,
                onRename: onRename,
                onEdit: onEdit
            )
        }
    }
}

private struct TrayTaskContextMenu: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let isCurrent: Bool
    let onSelect: (LoopTask) -> Void
    let onRename: (LoopTask) -> Void
    let onEdit: (LoopTask) -> Void

    var body: some View {
        if !isCurrent {
            Button {
                onSelect(task)
            } label: {
                Label("Focus", systemImage: "scope")
            }
        }

        if let linkedApp = task.linkedApp {
            Button {
                store.openLinkedApp(for: task)
            } label: {
                Label("Open \(linkedApp.name)", systemImage: "arrow.up.forward.app")
            }
        }

        if task.iterationTimerMinutes != nil {
            Menu {
                Button {
                    store.extendIterationTimer(for: task, by: 2)
                } label: {
                    Label("2 minutes", systemImage: "plus.circle")
                }

                Button {
                    store.extendIterationTimer(for: task, by: 5)
                } label: {
                    Label("5 minutes", systemImage: "plus.circle")
                }
            } label: {
                Label("Extend Timer", systemImage: "timer")
            }
        }

        Divider()

        Button {
            store.scheduleForNextWorkingDay(task)
        } label: {
            Label("Schedule for Next Day", systemImage: "calendar.badge.clock")
        }

        Button {
            store.snooze(task, minutes: 30)
        } label: {
            Label("Snooze 30 Minutes", systemImage: "clock")
        }

        Menu {
            ForEach(SnoozePreset.secondaryOptions) { preset in
                Button {
                    store.snooze(task, minutes: preset.minutes)
                } label: {
                    Label(preset.title, systemImage: preset.systemImage)
                }
            }

            Divider()

            Button {
                store.moveToBacklog(task)
            } label: {
                Label("Move to Inbox", systemImage: "tray.and.arrow.down")
            }
        } label: {
            Label("Snooze for…", systemImage: "clock.badge.questionmark")
        }

        Divider()

        Button {
            onRename(task)
        } label: {
            Label("Rename", systemImage: "text.cursor")
        }

        Button {
            onEdit(task)
        } label: {
            Label("Edit Details", systemImage: "slider.horizontal.3")
        }

        Button {
            store.togglePriority(task)
        } label: {
            Label(
                task.isPriority ? "Remove Priority" : "Mark Priority",
                systemImage: task.isPriority ? "star.slash" : "star"
            )
        }

        Button {
            store.moveToBacklog(task)
        } label: {
            Label("Move to Inbox", systemImage: "tray.and.arrow.down")
        }

        Button {
            store.finish(task)
        } label: {
            Label("Finish", systemImage: "checkmark.seal")
        }

        Divider()

        Button(role: .destructive) {
            store.delete(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
