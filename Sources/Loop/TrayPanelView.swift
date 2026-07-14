import SwiftUI

struct TrayPanelView: View {
    @EnvironmentObject private var store: TaskStore

    let onPrimaryAction: () -> Void
    let onSelectTask: (LoopTask) -> Void
    let onEditTask: (LoopTask) -> Void
    let onOpenTaskManager: () -> Void
    let onOpenSettings: () -> Void
    let onOpenStats: () -> Void

    @State private var quickTaskTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Loop")
                        .font(.headline)
                    Text("Iteration \(store.loopNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                productivityBadge

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

            statusCard

            Button(action: onPrimaryAction) {
                Label(primaryActionTitle, systemImage: primaryActionIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            iterationQueue

            Divider()

            quickTaskInput
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial)
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

                Text("\(openTasks.count) open")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if openTasks.isEmpty {
                Text("All tasks are done")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(openTasks) { task in
                            TrayTaskRow(
                                task: task,
                                isCurrent: task.id == currentTask?.id,
                                onSelect: onSelectTask,
                                onEdit: onEditTask
                            )
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
                    .lineLimit(1)
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
                    onEdit: onEditTask
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
        return "No current task"
    }

    private var statusEyebrow: String {
        if store.isInMeeting {
            return "Current status"
        }
        if store.isInRoutine {
            return "Current routine"
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
            return "Current focus"
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
        return .accentColor
    }

    private var primaryActionTitle: String {
        if store.isInMeeting {
            return "End meeting"
        }
        if store.isOnBreak {
            return "End break"
        }
        if store.isInRoutine {
            return "Finish routine"
        }
        return "Start break"
    }

    private var primaryActionIcon: String {
        if store.isInMeeting {
            return "video.slash"
        }
        if store.isOnBreak {
            return "play.fill"
        }
        if store.isInRoutine {
            return "checkmark"
        }
        return "cup.and.saucer"
    }

    private var currentTask: LoopTask? {
        if let focusedTask = store.focusedTask {
            return focusedTask
        }
        guard let focusedTaskID = store.focusedTaskID else { return nil }
        return store.tasks.first { $0.id == focusedTaskID && !$0.doneThisLoop && !$0.finished }
    }

    private var openTasks: [LoopTask] {
        store.currentLoopTasks.filter { !$0.doneThisLoop && !$0.finished }
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

}

private struct TrayTaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let isCurrent: Bool
    let onSelect: (LoopTask) -> Void
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
    let onEdit: (LoopTask) -> Void

    var body: some View {
        if !isCurrent {
            Button("Focus", systemImage: "scope") {
                onSelect(task)
            }
        }

        Button("Edit…", systemImage: "pencil") {
            onEdit(task)
        }

        Divider()

        Button(
            task.isPriority ? "Remove Priority" : "Mark Priority",
            systemImage: task.isPriority ? "star.slash" : "star"
        ) {
            store.togglePriority(task)
        }

        Button("Snooze 30 Minutes", systemImage: "clock") {
            store.snooze(task, minutes: 30)
        }

        Button("Move to Inbox", systemImage: "tray.and.arrow.down") {
            store.moveToBacklog(task)
        }

        Button("Finish Task", systemImage: "checkmark.seal") {
            store.finish(task)
        }

        Divider()

        Button("Delete Task", systemImage: "trash", role: .destructive) {
            store.delete(task)
        }
    }
}
