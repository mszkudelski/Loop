import AppKit
import SwiftUI

private extension View {
    func loopHelp(_ text: String) -> some View {
        modifier(LoopTooltipModifier(text: text))
    }
}

private struct LoopTooltipModifier: ViewModifier {
    let text: String
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { hovering in
                isHovered = hovering
            }
            .background(LoopTooltipHost(text: text, isVisible: isHovered).frame(width: 0, height: 0))
    }
}

private struct LoopTooltipHost: NSViewRepresentable {
    let text: String
    let isVisible: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if isVisible {
                context.coordinator.show(text: text, relativeTo: nsView)
            } else {
                context.coordinator.close()
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private var panel: NSPanel?

        func show(text: String, relativeTo view: NSView) {
            guard let window = view.window else { return }

            let tooltipPanel = panel ?? NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            tooltipPanel.contentView = NSHostingView(rootView: LoopTooltipBubble(text: text))
            tooltipPanel.backgroundColor = .clear
            tooltipPanel.isOpaque = false
            tooltipPanel.hasShadow = true
            tooltipPanel.hidesOnDeactivate = false
            tooltipPanel.isFloatingPanel = true
            tooltipPanel.ignoresMouseEvents = true
            tooltipPanel.level = .statusBar
            tooltipPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            tooltipPanel.setContentSize(tooltipPanel.contentView?.fittingSize ?? NSSize(width: 80, height: 26))

            position(tooltipPanel, relativeTo: view, in: window)
            panel = tooltipPanel
            tooltipPanel.orderFrontRegardless()
        }

        func close() {
            panel?.close()
            panel = nil
        }

        private func position(_ panel: NSPanel, relativeTo view: NSView, in window: NSWindow) {
            let viewFrameInWindow = view.convert(view.bounds, to: nil)
            let viewFrameOnScreen = window.convertToScreen(viewFrameInWindow)
            let size = panel.frame.size
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let padding: CGFloat = 8

            var x = viewFrameOnScreen.midX - (size.width / 2)
            var y = viewFrameOnScreen.maxY + padding
            if y + size.height > screenFrame.maxY - padding {
                y = viewFrameOnScreen.minY - size.height - padding
            }

            x = min(max(x, screenFrame.minX + padding), screenFrame.maxX - size.width - padding)
            y = min(max(y, screenFrame.minY + padding), screenFrame.maxY - size.height - padding)
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
    }
}

private struct LoopTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(nsColor: .labelColor))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
            .fixedSize()
    }
}

struct LoopPanelView: View {
    @EnvironmentObject private var store: TaskStore

    let onChooseApplication: () -> LinkedApp?

    @State private var newTaskTitle = ""
    @State private var editingTask: LoopTask?
    @State private var editingRoutine: RoutineBlock?
    @State private var isAddingDetailedTask = false
    @State private var isShowingBacklog = false
    @State private var isShowingSettings = false
    @State private var isShowingMorningOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                LoopTasksView(editingTask: $editingTask, editingRoutine: $editingRoutine) {
                    isAddingDetailedTask = true
                } onShowBacklog: {
                    isShowingBacklog = true
                }
                .allowsHitTesting(!store.isOnBreak)
                .blur(radius: store.isOnBreak ? 1.5 : 0)

                if store.isOnBreak {
                    BreakOverlayView()
                        .environmentObject(store)
                        .zIndex(1)
                }
            }
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
        .sheet(item: $editingRoutine) { routine in
            RoutineEditorView(routine: routine, onChooseApplication: onChooseApplication) { updatedRoutine in
                store.updateRoutineBlock(updatedRoutine)
            }
        }
        .sheet(isPresented: $isAddingDetailedTask) {
            TaskEditorView(task: nil, onChooseApplication: onChooseApplication) { newTask in
                store.addTask(
                    title: newTask.title,
                    linkedApp: newTask.linkedApp,
                    cadence: newTask.cadence,
                    iterationTimerMinutes: newTask.iterationTimerMinutes,
                    scheduledFor: newTask.scheduledFor,
                    addToIteration: !newTask.isBacklog
                )
            }
        }
        .sheet(isPresented: $isShowingBacklog) {
            BacklogPanelView(onChooseApplication: onChooseApplication)
                .environmentObject(store)
        }
        .sheet(isPresented: $isShowingMorningOnboarding, onDismiss: {
            store.markMorningOnboardingShown()
        }) {
            MorningOnboardingView(onChooseApplication: onChooseApplication)
                .environmentObject(store)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsPanelView(
                initialSection: .general,
                onChooseApplication: onChooseApplication,
                onClose: {
                    isShowingSettings = false
                }
            )
                .environmentObject(store)
                .onDisappear {
                    isShowingSettings = false
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loopShouldEditTask)) { notification in
            guard
                let taskID = notification.object as? UUID,
                let task = store.tasks.first(where: { $0.id == taskID })
            else {
                return
            }
            editingTask = task
        }
        .onReceive(NotificationCenter.default.publisher(for: .loopShouldCheckMorningOnboarding)) { _ in
            showMorningOnboardingIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .loopPopoverWillClose)) { _ in
            resetTransientPresentation()
        }
        .onAppear {
            showMorningOnboardingIfNeeded()
        }
        .onChange(of: store.currentDate) { _ in
            showMorningOnboardingIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Loop")
                    .font(.title2.weight(.semibold))
                Text("Iteration \(store.loopNumber)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                HeaderStatChip(value: "\(store.loopsCompletedToday)", label: "loops", color: Color(nsColor: .systemGreen))
                HeaderStatChip(value: "\(store.tasksFinishedToday.count)", label: "done", color: Color(nsColor: .systemBlue))
                HeaderStatChip(value: "\(productivityPercentage)%", label: "prod.", color: .secondary)
            }

            Button {
                isShowingMorningOnboarding = true
            } label: {
                Image(systemName: "sun.max")
                    .font(.title3)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .loopHelp("Plan iteration")

            if store.isOnBreak {
                Button {
                    store.endBreak()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .loopHelp("End break")
            }

            Button {
                store.advanceLoop()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .loopHelp("Next iteration")

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .loopHelp("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
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
                    .loopHelp("Dismiss notice")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 8) {
                PanelReturnAwareTextField(
                    placeholder: "New task",
                    text: $newTaskTitle,
                    onReturn: { _ in
                        addQuickTask()
                    },
                    onCommandReturn: { _ in
                        addQuickBacklogTask()
                    }
                )
                .frame(height: 24)
                .loopHelp("Enter adds task, Command Enter adds to Inbox")

                Button {
                    addQuickTask()
                } label: {
                    Text("Now")
                        .frame(width: 42, height: 24)
                }
                .buttonStyle(FooterControlButtonStyle(isProminent: true))
                .loopHelp("Add to current iteration")

                Button {
                    addQuickBacklogTask()
                } label: {
                    Text("Inbox")
                        .frame(width: 52, height: 24)
                }
                .buttonStyle(FooterControlButtonStyle())
                .loopHelp("Add to Inbox")

                Button {
                    isAddingDetailedTask = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .frame(width: 36, height: 24)
                }
                .buttonStyle(FooterControlButtonStyle())
                .loopHelp("Add with details")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    private func addQuickTask() {
        store.addTask(title: newTaskTitle)
        newTaskTitle = ""
    }

    private func addQuickBacklogTask() {
        store.addTask(title: newTaskTitle, addToIteration: false)
        newTaskTitle = ""
    }

    private func showMorningOnboardingIfNeeded() {
        guard store.shouldShowMorningOnboarding else { return }
        guard !isShowingMorningOnboarding else { return }
        isShowingMorningOnboarding = true
    }

    private func resetTransientPresentation() {
        editingTask = nil
        isAddingDetailedTask = false
        isShowingBacklog = false
        isShowingSettings = false
        isShowingMorningOnboarding = false
    }
}

private struct PanelReturnAwareTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onReturn: (String) -> Void
    let onCommandReturn: (String) -> Void

    func makeNSView(context: Context) -> PanelKeyHandlingTextField {
        let textField = PanelKeyHandlingTextField()
        textField.placeholderString = placeholder
        textField.bezelStyle = .roundedBezel
        textField.isBordered = true
        textField.drawsBackground = true
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.delegate = context.coordinator
        textField.onCommandReturn = onCommandReturn
        context.coordinator.onReturn = onReturn
        context.coordinator.onCommandReturn = onCommandReturn
        context.coordinator.onTextChange = { text = $0 }
        return textField
    }

    func updateNSView(_ nsView: PanelKeyHandlingTextField, context: Context) {
        nsView.stringValue = text
        nsView.placeholderString = placeholder
        nsView.onCommandReturn = onCommandReturn
        context.coordinator.onReturn = onReturn
        context.coordinator.onCommandReturn = onCommandReturn
        context.coordinator.onTextChange = { text = $0 }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onReturn: ((String) -> Void)?
        var onCommandReturn: ((String) -> Void)?
        var onTextChange: ((String) -> Void)?

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
            onTextChange?(textField.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let submitCommands: Set<Selector> = [
                #selector(NSResponder.insertNewline(_:)),
                #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                #selector(NSResponder.insertLineBreak(_:))
            ]
            guard submitCommands.contains(commandSelector) else {
                return false
            }

            let currentText = textView.string
            text = currentText
            let modifierFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                onCommandReturn?(currentText)
            } else {
                onReturn?(currentText)
            }
            return true
        }
    }
}

private final class PanelKeyHandlingTextField: NSTextField {
    var onCommandReturn: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 else {
            return super.performKeyEquivalent(with: event)
        }

        onCommandReturn?(currentEditor()?.string ?? stringValue)
        return true
    }
}

private struct FooterControlButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .overlay {
                if !isProminent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isProminent {
            return Color.accentColor.opacity(isPressed ? 0.82 : 1)
        }
        return Color(nsColor: .controlBackgroundColor)
            .opacity(isPressed ? 0.72 : 0.96)
    }
}

private struct HeaderStatChip: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(value)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct BreakOverlayView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 4) {
                Text("Break")
                    .font(.title3.weight(.semibold))
                Text(remainingText)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if store.isBreakTimeUp {
                    Text("Time is up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                store.endBreak()
            } label: {
                Label("End break", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .loopHelp("End break")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var remainingText: String {
        guard !store.isBreakTimeUp else { return "Done" }
        let seconds = store.breakRemainingSeconds
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct RoutineOverlayView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 4) {
                Text(store.activeRoutineBlock?.title ?? "Routine")
                    .font(.title3.weight(.semibold))
                Text(remainingText)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if store.isRoutineTimeUp {
                    Text("Time is up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.endRoutineBlock(markComplete: false)
                } label: {
                    Label("Skip", systemImage: "forward")
                }
                .loopHelp("End without completing")

                Button {
                    store.endRoutineBlock()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .loopHelp("Complete routine")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var remainingText: String {
        guard !store.isRoutineTimeUp else { return "Done" }
        let seconds = store.routineRemainingSeconds
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct LoopTasksView: View {
    @EnvironmentObject private var store: TaskStore
    @Binding var editingTask: LoopTask?
    @Binding var editingRoutine: RoutineBlock?
    @State private var draggingTaskID: UUID?
    @State private var lastDropTargetID: UUID?
    @State private var selectedTab: LoopListTab?
    let onAddTask: () -> Void
    let onShowBacklog: () -> Void
    private let shouldShowHintSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if shouldShowHintSuggestions, store.shouldSuggestAddingTaskToFastLoop {
                        LoopSuggestionRow(
                            message: "You are moving through a short loop quickly. Add another task?",
                            actionTitle: "Add task",
                            systemImage: "plus.circle",
                            action: onAddTask,
                            onDismiss: store.dismissFastLoopSuggestion
                        )
                    }

                    selectedTaskSection
                }
                .padding(16)
            }

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    LoopBottomTabButton(
                        title: "Done",
                        count: store.doneTasks.count + store.doneRoutineBlocks.count,
                        systemImage: "checkmark.circle",
                        isSelected: selectedTab == .done
                    ) {
                        toggleTab(.done)
                    }

                    LoopBottomTabButton(
                        title: "Future",
                        count: store.upcomingTasks.count,
                        systemImage: "calendar.badge.clock",
                        isSelected: selectedTab == .future
                    ) {
                        toggleTab(.future)
                    }

                    LoopBottomTabButton(
                        title: "Inbox",
                        count: store.backlogTasks.count,
                        systemImage: "tray.and.arrow.down",
                        isSelected: selectedTab == .inbox
                    ) {
                        toggleTab(.inbox)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.28))
        }
    }

    private var openTasks: [LoopTask] {
        store.currentLoopTasks.filter { !$0.doneThisLoop }
    }

    private var openItems: [LoopOpenItem] {
        openTasks.map(LoopOpenItem.task)
            + store.openRoutineBlocks.map(LoopOpenItem.routine)
    }

    @ViewBuilder
    private var selectedTaskSection: some View {
        switch selectedTab {
        case nil:
            TaskSection(title: "Open", tasks: openItems, emptyTitle: "No open tasks") { item in
                switch item {
                case .routine(let routine):
                    RoutineDueRow(routine: routine) {
                        editingRoutine = routine
                    }
                case .task(let task):
                    activeTaskRow(task)
                }
            }
        case .future:
            TaskSection(title: "Future", tasks: store.upcomingTasks, emptyTitle: "No future tasks") { task in
                TaskRow(task: task, usesFutureActions: true) {
                    editingTask = task
                }
            }
        case .inbox:
            TaskSection(title: "Inbox", tasks: store.backlogTasks, emptyTitle: "No inbox tasks") { task in
                TaskRow(task: task) {
                    editingTask = task
                }
            }
        case .done:
            TaskSection(title: "Done", tasks: doneItems, emptyTitle: "No done items") { item in
                switch item {
                case .task(let task):
                    TaskRow(task: task) {
                        editingTask = task
                    }
                case .routine(let routine):
                    CompactRoutineRow(routine: routine, onEdit: {
                        editingRoutine = routine
                    })
                }
            }
        }
    }

    private var doneItems: [LoopDoneItem] {
        store.doneTasks.map(LoopDoneItem.task) + store.doneRoutineBlocks.map(LoopDoneItem.routine)
    }

    private func activeTaskRow(_ task: LoopTask) -> some View {
        TaskRow(task: task, isOpenPresentation: true) {
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

    private func toggleTab(_ tab: LoopListTab) {
        withAnimation(.easeInOut(duration: 0.16)) {
            selectedTab = selectedTab == tab ? nil : tab
        }
    }
}

private enum LoopListTab {
    case done
    case future
    case inbox
}

private struct LoopBottomTabButton: View {
    let title: String
    let count: Int
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, height: 14)

                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .loopHelp(title)
    }
}

private enum LoopOpenItem: Identifiable {
    case routine(RoutineBlock)
    case task(LoopTask)

    var id: String {
        switch self {
        case .routine(let routine): "routine-\(routine.id.uuidString)"
        case .task(let task): "task-\(task.id.uuidString)"
        }
    }
}

private struct RoutineDueRow: View {
    @EnvironmentObject private var store: TaskStore

    let routine: RoutineBlock
    let onEdit: () -> Void

    private var isActive: Bool {
        store.activeRoutineBlockID == routine.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                toggleRoutine()
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .loopHelp(isActive ? "Complete routine" : "Start routine")

            Button {
                if !isActive {
                    store.startRoutineBlock(routine)
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(routine.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "clock.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemTeal))
                            .loopHelp("Routine")
                    }

                    HStack(spacing: 8) {
                        CadenceBadge(cadence: routine.cadence)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TimerBadge(minutes: routine.durationMinutes, remainingSeconds: isActive ? store.routineRemainingSeconds : nil)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !routine.scheduleTimes.isEmpty {
                            RoutineScheduleBadge(scheduleTimes: routine.scheduleTimes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let appName = routine.linkedApp?.name {
                            Text(appName)
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
        .background(isActive ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 7)
            }
        }
        .contextMenu {
            Button {
                toggleRoutine()
            } label: {
                Label(isActive ? "Complete Routine" : "Start Routine", systemImage: isActive ? "checkmark" : "play")
            }

            if isActive {
                Button {
                    store.endRoutineBlock(markComplete: false)
                } label: {
                    Label("Skip Routine", systemImage: "forward.end")
                }
            } else {
                Button {
                    store.snoozeRoutine(routine, minutes: 30)
                } label: {
                    Label("Snooze 30 minutes", systemImage: "clock")
                }
            }

            Divider()

            RoutineCadenceMenu(routine: routine)

            Button {
                onEdit()
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

            Button {
                store.deleteRoutineBlock(routine)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func toggleRoutine() {
        if isActive {
            store.endRoutineBlock(markComplete: true)
        } else {
            store.startRoutineBlock(routine)
        }
    }
}

private struct LoopSuggestionRow: View {
    let message: String
    let actionTitle: String
    let systemImage: String
    let action: () -> Void
    let onDismiss: (() -> Void)?

    init(
        message: String,
        actionTitle: String,
        systemImage: String,
        action: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.message = message
        self.actionTitle = actionTitle
        self.systemImage = systemImage
        self.action = action
        self.onDismiss = onDismiss
    }

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
            .loopHelp(actionTitle)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .loopHelp("Dismiss")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TaskSection<Item: Identifiable, Content: View>: View {
    let title: String?
    let tasks: [Item]
    let emptyTitle: String
    @ViewBuilder let row: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
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

private struct CollapsibleTaskSection<Content: View>: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)

                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
    }
}

private struct CompactTaskList: View {
    let tasks: [LoopTask]
    let emptyTitle: String
    let visibleLimit: Int
    let onEdit: (LoopTask) -> Void

    private var visibleTasks: [LoopTask] {
        Array(tasks.prefix(max(visibleLimit, 0)))
    }

    private var remainingCount: Int {
        max(0, tasks.count - visibleTasks.count)
    }

    var body: some View {
        Group {
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleTasks) { task in
                        CompactTaskRow(task: task) {
                            onEdit(task)
                        }
                    }

                    if remainingCount > 0 {
                        Text("+ \(remainingCount) more")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

private struct CompactDoneList: View {
    let tasks: [LoopTask]
    let routines: [RoutineBlock]
    let emptyTitle: String
    let visibleLimit: Int
    let onEdit: (LoopTask) -> Void

    private var items: [LoopDoneItem] {
        tasks.map(LoopDoneItem.task) + routines.map(LoopDoneItem.routine)
    }

    private var visibleItems: [LoopDoneItem] {
        Array(items.prefix(max(visibleLimit, 0)))
    }

    private var remainingCount: Int {
        max(0, items.count - visibleItems.count)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                Text(emptyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleItems) { item in
                        switch item {
                        case .task(let task):
                            CompactTaskRow(task: task) {
                                onEdit(task)
                            }
                        case .routine(let routine):
                            CompactRoutineRow(routine: routine)
                        }
                    }

                    if remainingCount > 0 {
                        Text("+ \(remainingCount) more")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

private enum LoopDoneItem: Identifiable {
    case task(LoopTask)
    case routine(RoutineBlock)

    var id: String {
        switch self {
        case .task(let task): "task-\(task.id.uuidString)"
        case .routine(let routine): "routine-\(routine.id.uuidString)"
        }
    }
}

private struct CompactRoutineRow: View {
    @EnvironmentObject private var store: TaskStore

    let routine: RoutineBlock
    let onEdit: (() -> Void)?

    init(routine: RoutineBlock, onEdit: (() -> Void)? = nil) {
        self.routine = routine
        self.onEdit = onEdit
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.reopenRoutineBlock(routine)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .loopHelp("Reopen routine")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(routine.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .strikethrough(true, color: .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "clock.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .systemTeal))
                        .loopHelp("Routine")
                }

                HStack(spacing: 6) {
                    CadenceBadge(cadence: routine.cadence)

                    TimerBadge(minutes: routine.durationMinutes, remainingSeconds: nil)

                    if !routine.scheduleTimes.isEmpty {
                        RoutineScheduleBadge(scheduleTimes: routine.scheduleTimes)
                    }

                    if let appName = routine.linkedApp?.name {
                        Text(appName)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button {
                store.reopenRoutineBlock(routine)
            } label: {
                Label("Reopen Routine", systemImage: "arrow.uturn.backward")
            }

            RoutineCadenceMenu(routine: routine)

            if let onEdit {
                Button {
                    onEdit()
                } label: {
                    Label("Edit Details", systemImage: "slider.horizontal.3")
                }
            }

            Button {
                store.setRoutineEnabled(routine, isEnabled: !routine.isEnabled)
            } label: {
                Label(
                    routine.isEnabled ? "Disable Routine" : "Enable Routine",
                    systemImage: routine.isEnabled ? "clock.badge.xmark" : "clock.badge.checkmark"
                )
            }

            Button {
                store.deleteRoutineBlock(routine)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct CompactTaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggleDone(task)
            } label: {
                Image(systemName: task.doneThisLoop ? "checkmark.circle.fill" : compactIconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .loopHelp(task.doneThisLoop ? "Reopen" : "Done")

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(task.doneThisLoop ? .secondary : .primary)
                        .strikethrough(task.doneThisLoop, color: .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    compactMetadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var compactIconName: String {
        if task.scheduledFor != nil { return "calendar.badge.clock" }
        if task.isPriority { return "star.fill" }
        return "circle"
    }

    @ViewBuilder
    private var compactMetadata: some View {
        HStack(spacing: 6) {
            if let scheduledFor = task.scheduledFor, scheduledFor > store.currentDate {
                TaskScheduleBadge(scheduledFor: scheduledFor)
            } else {
                CadenceBadge(cadence: task.cadence)
            }

            if let appName = task.linkedApp?.name {
                Text(appName)
                    .lineLimit(1)
            }

            if let nextDueLoop = store.nextDueLoop(for: task), nextDueLoop > store.loopNumber {
                Text("Loop \(nextDueLoop)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var store: TaskStore
    @FocusState private var isTitleFocused: Bool

    let task: LoopTask
    /// Open items must remain legible even while a task-state update is propagating.
    /// Completed styling belongs exclusively to the Done presentation.
    let isOpenPresentation: Bool
    let usesFutureActions: Bool
    let onEdit: () -> Void

    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    private let shouldShowHintSuggestions = false

    init(
        task: LoopTask,
        isOpenPresentation: Bool = false,
        usesFutureActions: Bool = false,
        onEdit: @escaping () -> Void
    ) {
        self.task = task
        self.isOpenPresentation = isOpenPresentation
        self.usesFutureActions = usesFutureActions
        self.onEdit = onEdit
    }

    var body: some View {
        let isFocused = store.currentFocusTaskID == task.id
        let isSnoozed = store.isSnoozed(task)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    endTitleEdit(commit: true)
                    store.toggleDone(task)
                } label: {
                    Image(systemName: task.isBacklog ? "tray" : (task.doneThisLoop ? "checkmark.circle.fill" : "circle"))
                        .font(.title3)
                        .foregroundStyle(task.doneThisLoop ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(task.isBacklog)
                .loopHelp(task.isBacklog ? "Inbox" : (task.doneThisLoop ? "Reopen" : "Done"))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isEditingTitle {
                            TextField("", text: $draftTitle)
                                .textFieldStyle(.plain)
                                .font(.body.weight(.medium))
                                .focused($isTitleFocused)
                                .onSubmit {
                                    endTitleEdit(commit: true)
                                }
                                .onExitCommand {
                                    endTitleEdit(commit: false)
                                }
                        } else {
                            Button {
                                beginTitleEdit()
                            } label: {
                                Text(task.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(isVisuallyCompleted ? .secondary : .primary)
                                    .strikethrough(isVisuallyCompleted, color: .secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .loopHelp("Rename")
                        }

                        if task.isPriority {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .loopHelp("Priority")
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

                        if let scheduledFor = task.scheduledFor, scheduledFor > store.currentDate {
                            TaskScheduleBadge(scheduledFor: scheduledFor)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let appName = task.linkedApp?.name {
                            Text(appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if isSnoozed {
                            Label("Snoozed", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let nextDueLoop = store.nextDueLoop(for: task), nextDueLoop > store.loopNumber {
                            Label("Loop \(nextDueLoop)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    if usesFutureActions {
                        futureTaskActions()
                    } else {
                        taskActions(isFocused: isFocused, isSnoozed: isSnoozed)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .opacity(isHovered || isEditingTitle ? 1 : 0)
                .disabled(!(isHovered || isEditingTitle))
                .loopHelp("More")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(taskRowBackground(isFocused: isFocused, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFocused ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                if isFocused {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onChange(of: isTitleFocused) { focused in
                if !focused && isEditingTitle {
                    endTitleEdit(commit: true)
                }
            }
            .contextMenu {
                if usesFutureActions {
                    futureTaskActions()
                } else {
                    taskActions(isFocused: isFocused, isSnoozed: isSnoozed)
                }
            }

            if shouldShowHintSuggestions, let suggestion = store.suggestion(for: task) {
                LoopSuggestionRow(
                    message: suggestion.message,
                    actionTitle: suggestion.actionTitle,
                    systemImage: suggestion.systemImage
                ) {
                    perform(suggestion)
                } onDismiss: {
                    store.dismissSuggestion(suggestion, for: task)
                }
            }
        }
    }

    private func taskRowBackground(isFocused: Bool, isHovered: Bool) -> Color {
        if isFocused {
            return Color.accentColor.opacity(isHovered ? 0.2 : 0.14)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.94 : 0.78)
    }

    private var isVisuallyCompleted: Bool {
        task.doneThisLoop && !isOpenPresentation
    }

    @ViewBuilder
    private func futureTaskActions() -> some View {
        Button {
            store.clearSchedule(for: task)
        } label: {
            Label("Add Now", systemImage: "calendar.badge.clock")
        }

        Button {
            store.scheduleForNextWorkingDay(task)
        } label: {
            Label("Schedule for Next Day", systemImage: "calendar.badge.clock")
        }

        Divider()

        Button {
            onEdit()
        } label: {
            Label("Edit Details", systemImage: "slider.horizontal.3")
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

        Button {
            store.delete(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func taskActions(isFocused: Bool, isSnoozed: Bool) -> some View {
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
                    Label("Extend timer", systemImage: "timer")
                }
            }

            Divider()
        }

        if !task.isBacklog {
            Button {
                store.scheduleForNextWorkingDay(task)
            } label: {
                Label("Schedule for Next Day", systemImage: "calendar.badge.clock")
            }
        }

        if !task.isBacklog && isSnoozed {
            Button {
                store.unsnooze(task)
            } label: {
                Label("Unsnooze", systemImage: "clock.arrow.circlepath")
            }
        } else if !task.isBacklog, task.scheduledFor.map({ $0 > store.currentDate }) == true {
            Button {
                store.clearSchedule(for: task)
            } label: {
                Label("Add Now", systemImage: "calendar.badge.clock")
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
                Label("Snooze for...", systemImage: "clock.badge.questionmark")
            }
        }

        Divider()

        Button {
            beginTitleEdit()
        } label: {
            Label("Rename", systemImage: "text.cursor")
        }

        Button {
            onEdit()
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

        if !task.isBacklog {
            Button {
                store.moveToBacklog(task)
            } label: {
                Label("Move to Inbox", systemImage: "tray.and.arrow.down")
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

    private func beginTitleEdit() {
        draftTitle = task.title
        isEditingTitle = true
        DispatchQueue.main.async {
            isTitleFocused = true
        }
    }

    private func endTitleEdit(commit: Bool) {
        guard isEditingTitle else { return }
        let title = draftTitle
        isEditingTitle = false
        isTitleFocused = false
        if commit {
            store.updateTaskTitle(task, title: title)
        } else {
            draftTitle = task.title
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

struct SnoozePreset: Identifiable {
    let title: String
    let minutes: Int
    let systemImage: String

    var id: Int { minutes }

    static let secondaryOptions = [
        SnoozePreset(title: "15 minutes", minutes: 15, systemImage: "clock"),
        SnoozePreset(title: "1 hour", minutes: 60, systemImage: "clock"),
        SnoozePreset(title: "2 hours", minutes: 120, systemImage: "clock"),
        SnoozePreset(title: "4 hours", minutes: 240, systemImage: "clock")
    ]
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

private struct RoutineCadenceMenu: View {
    @EnvironmentObject private var store: TaskStore

    let routine: RoutineBlock

    private let quickCadences = [1, 2, 3, 4, 5, 7, 10, 14]

    var body: some View {
        Menu {
            Button {
                updateCadence(by: -1)
            } label: {
                Label("More often", systemImage: "minus")
            }
            .disabled(routine.cadence.rawValue == 1)

            Button {
                updateCadence(by: 1)
            } label: {
                Label("Less often", systemImage: "plus")
            }
            .disabled(routine.cadence.rawValue == LoopCadence.maxLoops)

            Divider()

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

    private func updateCadence(by amount: Int) {
        store.updateRoutineCadence(
            routine,
            to: LoopCadence(rawValue: routine.cadence.rawValue + amount)
        )
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
        return TaskStore.timerText(forRemainingSeconds: remainingSeconds)
    }
}

private struct TaskScheduleBadge: View {
    let scheduledFor: Date

    var body: some View {
        Label(scheduleText, systemImage: "calendar.badge.clock")
            .lineLimit(1)
    }

    private var scheduleText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(scheduledFor) {
            return "Today \(ScheduleFormatters.time.string(from: scheduledFor))"
        }
        if calendar.isDateInTomorrow(scheduledFor) {
            return "Tomorrow \(ScheduleFormatters.time.string(from: scheduledFor))"
        }
        return ScheduleFormatters.shortDateTime.string(from: scheduledFor)
    }
}

private struct RoutineScheduleBadge: View {
    let scheduleTimes: [DailyScheduleTime]

    var body: some View {
        Label(scheduleText, systemImage: "clock")
            .lineLimit(1)
    }

    private var scheduleText: String {
        scheduleTimes
            .sorted()
            .map { scheduleTime in
                String(format: "%02d:%02d", scheduleTime.hour, scheduleTime.minute)
            }
            .joined(separator: ", ")
    }
}

private enum ScheduleFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
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

private struct MorningOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: TaskStore

    let onChooseApplication: () -> LinkedApp?

    @State private var newTaskTitle = ""
    @State private var editingTask: LoopTask?
    @State private var draggingTaskID: UUID?
    @State private var lastDropTargetID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning Plan")
                        .font(.title3.weight(.semibold))
                    Text("Iteration \(store.loopNumber)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    MorningPlanChip(value: "\(openIterationTasks.count)", label: "open", systemImage: "circle")
                    MorningPlanChip(value: "\(openIterationTasks.filter(\.isPriority).count)", label: "priority", systemImage: "star")
                    MorningPlanChip(value: "\(store.backlogTasks.count)", label: "inbox", systemImage: "tray")
                }

                Button {
                    store.markMorningOnboardingShown()
                    dismiss()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .loopHelp("Start iteration")
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quickAdd

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Iteration", count: iterationTasks.count)

                        if iterationTasks.isEmpty {
                            emptyRow("No open tasks")
                        } else {
                            ForEach(Array(iterationTasks.enumerated()), id: \.element.id) { index, task in
                                MorningIterationTaskRow(task: task, index: index, count: iterationTasks.count) {
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
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Move From Inbox", count: store.backlogTasks.count)

                        if store.backlogTasks.isEmpty {
                            emptyRow("No inbox tasks")
                        } else {
                            ForEach(store.backlogTasks) { task in
                                MorningBacklogTaskRow(task: task) {
                                    editingTask = task
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task, onChooseApplication: onChooseApplication) { updatedTask in
                store.updateTask(updatedTask)
            }
        }
    }

    private var iterationTasks: [LoopTask] {
        store.currentLoopTasks
    }

    private var openIterationTasks: [LoopTask] {
        iterationTasks.filter { !$0.doneThisLoop }
    }

    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Add", count: nil)

            HStack(spacing: 8) {
                PanelReturnAwareTextField(
                    placeholder: "New task",
                    text: $newTaskTitle,
                    onReturn: { _ in
                        addTask(addToIteration: true)
                    },
                    onCommandReturn: { _ in
                        addTask(addToIteration: false)
                    }
                )
                .frame(height: 26)
                .loopHelp("Enter adds to iteration, Command Enter adds to Inbox")

                Button {
                    addTask(addToIteration: true)
                } label: {
                    Text("Now")
                        .frame(width: 44, height: 26)
                }
                .buttonStyle(FooterControlButtonStyle(isProminent: true))
                .loopHelp("Add to iteration")

                Button {
                    addTask(addToIteration: false)
                } label: {
                    Text("Inbox")
                        .frame(width: 54, height: 26)
                }
                .buttonStyle(FooterControlButtonStyle())
                .loopHelp("Add to Inbox")
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer()

            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())
            }
        }
    }

    private func emptyRow(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func addTask(addToIteration: Bool) {
        store.addTask(title: newTaskTitle, addToIteration: addToIteration)
        newTaskTitle = ""
    }
}

private struct MorningPlanChip: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(value)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.86), in: Capsule())
    }
}

private struct MorningIterationTaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let index: Int
    let count: Int
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 24)
                .loopHelp("Drag to reorder")

            Button {
                store.togglePriority(task)
            } label: {
                Image(systemName: task.isPriority ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(task.isPriority ? .yellow : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .loopHelp(task.isPriority ? "Remove priority" : "Mark priority")

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(task.doneThisLoop ? .secondary : .primary)
                        .strikethrough(task.doneThisLoop, color: .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        CadenceBadge(cadence: task.cadence)

                        if let iterationTimerMinutes = task.iterationTimerMinutes {
                            TimerBadge(minutes: iterationTimerMinutes, remainingSeconds: nil)
                        }

                        if let scheduledFor = task.scheduledFor, scheduledFor > store.currentDate {
                            TaskScheduleBadge(scheduledFor: scheduledFor)
                        }

                        if let appName = task.linkedApp?.name {
                            Text(appName)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .loopHelp("Edit details")

            HStack(spacing: 2) {
                Button {
                    store.moveCurrentLoopTask(task, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 22, height: 22)
                }
                .disabled(index == 0)
                .loopHelp("Move up")

                Button {
                    store.moveCurrentLoopTask(task, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 22, height: 22)
                }
                .disabled(index == count - 1)
                .loopHelp("Move down")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .loopHelp("Edit details")

            Button {
                store.moveToBacklog(task)
            } label: {
                Image(systemName: "tray.and.arrow.down")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .loopHelp("Move to Inbox")

            Button {
                store.delete(task)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .loopHelp("Delete")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MorningBacklogTaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if task.isPriority {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .loopHelp("Priority")
                        }
                    }

                    HStack(spacing: 8) {
                        CadenceBadge(cadence: task.cadence)

                        if let iterationTimerMinutes = task.iterationTimerMinutes {
                            TimerBadge(minutes: iterationTimerMinutes, remainingSeconds: nil)
                        }

                        if let scheduledFor = task.scheduledFor {
                            TaskScheduleBadge(scheduledFor: scheduledFor)
                        }

                        if let appName = task.linkedApp?.name {
                            Text(appName)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .loopHelp("Edit details")

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .loopHelp("Edit details")

            Button {
                store.togglePriority(task)
            } label: {
                Image(systemName: task.isPriority ? "star.fill" : "star")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(task.isPriority ? .yellow : .secondary)
            .loopHelp(task.isPriority ? "Remove priority" : "Mark priority")

            Button {
                store.addToIteration(task)
            } label: {
                Image(systemName: "arrow.up.circle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .loopHelp("Add to iteration")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct BacklogPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: TaskStore

    let onChooseApplication: () -> LinkedApp?

    @State private var editingTask: LoopTask?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inbox")
                        .font(.title3.weight(.semibold))
                    Text("\(store.backlogTasks.count) \(store.backlogTasks.count == 1 ? "item" : "items")")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .loopHelp("Close")
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    TaskSection(title: "Inbox", tasks: store.backlogTasks, emptyTitle: "No inbox tasks") { task in
                        BacklogTaskRow(task: task) {
                            editingTask = task
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 500, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task, onChooseApplication: onChooseApplication) { updatedTask in
                store.updateTask(updatedTask)
            }
        }
    }
}

private struct BacklogTaskRow: View {
    @EnvironmentObject private var store: TaskStore

    let task: LoopTask
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if task.isPriority {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .loopHelp("Priority")
                    }
                }

                HStack(spacing: 8) {
                    CadenceBadge(cadence: task.cadence)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let iterationTimerMinutes = task.iterationTimerMinutes {
                        TimerBadge(minutes: iterationTimerMinutes, remainingSeconds: nil)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let scheduledFor = task.scheduledFor {
                        TaskScheduleBadge(scheduledFor: scheduledFor)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let appName = task.linkedApp?.name {
                        Text(appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Button {
                store.addToIteration(task)
            } label: {
                Image(systemName: "arrow.up.circle")
            }
            .loopHelp("Add to iteration")

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .loopHelp("Edit details")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button {
                store.addToIteration(task)
            } label: {
                Label("Add to Iteration", systemImage: "arrow.up.circle")
            }

            Button {
                onEdit()
            } label: {
                Label("Edit Details", systemImage: "slider.horizontal.3")
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
    }
}

struct SettingsPanelView: View {
    @State private var selectedSection: SettingsSection
    let onChooseApplication: () -> LinkedApp?
    let onClose: () -> Void

    init(initialSection: SettingsSection, onChooseApplication: @escaping () -> LinkedApp?, onClose: @escaping () -> Void) {
        _selectedSection = State(initialValue: initialSection)
        self.onChooseApplication = onChooseApplication
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: $selectedSection) {
                    ForEach(SettingsSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .loopHelp("Close")
            }
            .padding(16)

            Divider()

            switch selectedSection {
            case .general:
                GeneralSettingsView()
            case .routines:
                RoutineSettingsView(onChooseApplication: onChooseApplication)
            case .stats:
                StatisticsView()
            case .shortcuts:
                ShortcutSettingsView()
            }
        }
        .frame(width: 560, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case routines
    case stats
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .routines: "Routines"
        case .stats: "Stats"
        case .shortcuts: "Shortcuts"
        }
    }
}

private struct RoutineSettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var editingRoutine: RoutineBlock?
    @State private var isAddingRoutine = false

    let onChooseApplication: () -> LinkedApp?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Routine Blocks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    isAddingRoutine = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.routineBlocks.isEmpty {
                        Text("No routine blocks")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                    ForEach(store.routineBlocks) { routine in
                        RoutineSettingsRow(routine: routine) {
                                editingRoutine = routine
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .sheet(item: $editingRoutine) { routine in
            RoutineEditorView(routine: routine, onChooseApplication: onChooseApplication) { updatedRoutine in
                store.updateRoutineBlock(updatedRoutine)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $isAddingRoutine) {
            RoutineEditorView(routine: nil, onChooseApplication: onChooseApplication) { newRoutine in
                store.addRoutineBlock(
                    title: newRoutine.title,
                    linkedApp: newRoutine.linkedApp,
                    cadence: newRoutine.cadence,
                    durationMinutes: newRoutine.durationMinutes,
                    countsAsProductive: newRoutine.countsAsProductive,
                    isEnabled: newRoutine.isEnabled,
                    scheduleTimes: newRoutine.scheduleTimes
                )
            }
            .environmentObject(store)
        }
    }
}

private struct RoutineSettingsRow: View {
    @EnvironmentObject private var store: TaskStore

    let routine: RoutineBlock
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: routine.isEnabled ? "clock.badge.checkmark" : "clock.badge.xmark")
                .font(.title3)
                .foregroundStyle(routine.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(routine.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    CadenceBadge(cadence: routine.cadence)
                    TimerBadge(minutes: routine.durationMinutes, remainingSeconds: nil)
                    Text(routine.countsAsProductive ? "Productive" : "Not productive")
                    if !routine.scheduleTimes.isEmpty {
                        RoutineScheduleBadge(scheduleTimes: routine.scheduleTimes)
                    }
                    if let appName = routine.linkedApp?.name {
                        Text(appName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.startRoutineBlock(routine)
            } label: {
                Image(systemName: "play")
            }
            .disabled(!routine.isEnabled)
            .loopHelp("Start now")

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .loopHelp("Edit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button {
                store.startRoutineBlock(routine)
            } label: {
                Label("Start Now", systemImage: "play")
            }
            .disabled(!routine.isEnabled)

            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            RoutineCadenceMenu(routine: routine)

            Button {
                store.setRoutineEnabled(routine, isEnabled: !routine.isEnabled)
            } label: {
                Label(
                    routine.isEnabled ? "Disable Routine" : "Enable Routine",
                    systemImage: routine.isEnabled ? "clock.badge.xmark" : "clock.badge.checkmark"
                )
            }

            Button {
                store.deleteRoutineBlock(routine)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Toggle("Auto-open focused app", isOn: Binding(
                    get: {
                        store.autoOpenFocusedTaskApp
                    },
                    set: { isEnabled in
                        store.setAutoOpenFocusedTaskApp(isEnabled)
                    }
                ))
                .toggleStyle(.checkbox)

                Toggle("Open Loop at login", isOn: Binding(
                    get: {
                        store.openLoopAtLogin
                    },
                    set: { isEnabled in
                        store.setOpenLoopAtLogin(isEnabled)
                    }
                ))
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 8) {
                    Text("New tasks")
                        .font(.callout.weight(.semibold))

                    Picker("Add new tasks to", selection: newTaskIterationBinding) {
                        Text("Current iteration").tag(true)
                        Text("Next iteration").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Default iteration timer")
                        .font(.callout.weight(.semibold))

                    Stepper(value: defaultIterationTimerBinding, in: 0...240, step: 1) {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .foregroundStyle(.secondary)
                            Text(defaultIterationTimerText)
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 260, alignment: .leading)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Break duration")
                        .font(.callout.weight(.semibold))

                    Stepper(value: breakDurationBinding, in: 1...120, step: 1) {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .foregroundStyle(.secondary)
                            Text("\(store.breakDurationMinutes) minutes")
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 260, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var defaultIterationTimerBinding: Binding<Int> {
        Binding(
            get: {
                store.defaultIterationTimerMinutes
            },
            set: { minutes in
                store.setDefaultIterationTimerMinutes(minutes)
            }
        )
    }

    private var newTaskIterationBinding: Binding<Bool> {
        Binding(
            get: { store.newTasksStartInCurrentIteration },
            set: { store.setNewTasksStartInCurrentIteration($0) }
        )
    }

    private var defaultIterationTimerText: String {
        let minutes = store.defaultIterationTimerMinutes
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    private var breakDurationBinding: Binding<Int> {
        Binding(
            get: {
                store.breakDurationMinutes
            },
            set: { minutes in
                store.setBreakDurationMinutes(minutes)
            }
        )
    }
}

private struct StatisticsView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var selectedDate = Date()
    @State private var scope: StatisticsScope = .day
    @State private var mode: StatisticsMode = .summary
    @State private var isShowingActionTelemetry = false

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

                if scope != .total {
                    dateControls
                }

                Picker("", selection: $mode) {
                    ForEach(StatisticsMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .summary:
                    StatisticsSummaryView(
                        metrics: topMetrics,
                        productiveText: productiveDurationText,
                        breakText: breakDurationText,
                        meetingText: meetingDurationText,
                        routineText: routineDurationText,
                        productiveDuration: productiveDuration,
                        breakDuration: breakDuration,
                        meetingDuration: meetingDuration,
                        routineDuration: routineDuration,
                        productiveRatio: productiveRatio,
                        meetingCount: meetingCount,
                        breakCount: breakCount,
                        routineCount: routineCount,
                        activeWindowText: activeWindowText,
                        iterationsCount: iterationsCount,
                        finishedCount: finishedCount,
                        averageText: averageText,
                        finishedStats: finishedStats
                    )

                    if scope == .week {
                        WeekSummaryView(days: weekSummaryDays, style: .productivity)
                    }

                case .details:
                    LazyVGrid(columns: columns, spacing: 10) {
                        StatTile(title: "Iterations", value: "\(iterationsCount)", systemImage: "arrow.triangle.2.circlepath")
                        StatTile(title: "Finished", value: "\(finishedCount)", systemImage: "checkmark.seal")
                        StatTile(title: "Breaks", value: "\(breakCount)", systemImage: "cup.and.saucer")
                        StatTile(title: "Break time", value: breakDurationText, systemImage: "timer")
                        StatTile(title: "Meetings", value: "\(meetingCount)", systemImage: "video")
                        StatTile(title: "Meeting time", value: meetingDurationText, systemImage: "person.2.wave.2")
                        StatTile(title: "Routines", value: "\(routineCount)", systemImage: "clock.badge.checkmark")
                        StatTile(title: "Routine time", value: routineDurationText, systemImage: "timer")
                        StatTile(title: "Active time", value: activeDurationText, systemImage: "desktopcomputer")
                        StatTile(title: "Finished task focus", value: finishedTaskFocusText, systemImage: "checkmark.circle")
                        StatTile(title: "Unfinished task focus", value: unfinishedTaskFocusText, systemImage: "scope")
                        if scope == .day {
                            StatTile(title: "First active", value: firstActiveText, systemImage: "sunrise")
                            StatTile(title: "Last active", value: lastActiveText, systemImage: "sunset")
                        }
                        StatTile(title: "Productive", value: productiveDurationText, systemImage: "bolt")
                        StatTile(
                            title: "Avg Iterations / Task",
                            value: averageText,
                            systemImage: "chart.bar"
                        )
                        StatTile(
                            title: scope == .total ? "Days Active" : "All-Time Finished",
                            value: "\(referenceCount)",
                            systemImage: "list.bullet"
                        )
                    }

                    if scope == .week {
                        WeekSummaryView(days: weekSummaryDays, style: .full)
                    }

                    TaskSection(title: "Finished Tasks", tasks: finishedStats, emptyTitle: "No finished tasks") { stat in
                        CompletedTaskStatRow(stat: stat)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isShowingActionTelemetry.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .rotationEffect(.degrees(isShowingActionTelemetry ? 90 : 0))
                                .frame(width: 14, height: 14)

                            Label("Action telemetry", systemImage: "chart.bar.xaxis")
                                .font(.caption.weight(.semibold))

                            Spacer()

                            Text("\(actionTelemetryTotal)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if isShowingActionTelemetry {
                        ActionTelemetryDashboard(stats: store.actionTelemetry)
                    }
                }
            }
            .padding(16)
        }
    }

    private var dateControls: some View {
        HStack(spacing: 8) {
            Button {
                moveSelectedPeriod(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .loopHelp(scope == .week ? "Previous week" : "Previous day")

            Text(dayTitle)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)

            Button {
                moveSelectedPeriod(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(isSelectedPeriodCurrent)
            .loopHelp(scope == .week ? "Next week" : "Next day")

            Button("Today") {
                selectedDate = Date()
            }
            .disabled(isSelectedPeriodCurrent)
            .controlSize(.small)
        }
    }

    private var iterationsCount: Int {
        switch scope {
        case .day: store.loopsCompleted(on: selectedDate)
        case .week: store.loopsCompleted(in: selectedWeekInterval)
        case .total: store.loopsCompletedTotal
        }
    }

    private var finishedCount: Int {
        switch scope {
        case .day: store.tasksFinished(on: selectedDate).count
        case .week: store.tasksFinished(in: selectedWeekInterval).count
        case .total: store.completedTaskStats.count
        }
    }

    private var breakCount: Int {
        switch scope {
        case .day: store.breakCount(on: selectedDate)
        case .week: store.breakCount(in: selectedWeekInterval)
        case .total: store.breakCountTotal
        }
    }

    private var breakDurationText: String {
        StatisticsDurationFormatter.string(from: breakDuration)
    }

    private var breakDuration: TimeInterval {
        switch scope {
        case .day: store.breakDuration(on: selectedDate)
        case .week: store.breakDuration(in: selectedWeekInterval)
        case .total: store.breakDurationTotal
        }
    }

    private var meetingCount: Int {
        switch scope {
        case .day: store.meetingCount(on: selectedDate)
        case .week: store.meetingCount(in: selectedWeekInterval)
        case .total: store.meetingCountTotal
        }
    }

    private var meetingDurationText: String {
        StatisticsDurationFormatter.string(from: meetingDuration)
    }

    private var meetingDuration: TimeInterval {
        switch scope {
        case .day: store.meetingDuration(on: selectedDate)
        case .week: store.meetingDuration(in: selectedWeekInterval)
        case .total: store.meetingDurationTotal
        }
    }

    private var routineCount: Int {
        switch scope {
        case .day: store.routineCount(on: selectedDate)
        case .week: store.routineCount(in: selectedWeekInterval)
        case .total: store.routineCountTotal
        }
    }

    private var routineDurationText: String {
        StatisticsDurationFormatter.string(from: routineDuration)
    }

    private var routineDuration: TimeInterval {
        switch scope {
        case .day: store.routineDuration(on: selectedDate)
        case .week: store.routineDuration(in: selectedWeekInterval)
        case .total: store.routineDurationTotal
        }
    }

    private var activeDurationText: String {
        StatisticsDurationFormatter.string(from: activeDuration)
    }

    private var activeDuration: TimeInterval {
        switch scope {
        case .day: store.activeDuration(on: selectedDate)
        case .week: store.activeDuration(in: selectedWeekInterval)
        case .total: store.activeDurationTotal
        }
    }

    private var finishedTaskFocusText: String {
        taskFocusText(finished: true)
    }

    private var unfinishedTaskFocusText: String {
        taskFocusText(finished: false)
    }

    private func taskFocusText(finished: Bool) -> String {
        let duration: TimeInterval
        let count: Int
        switch scope {
        case .day:
            guard let interval = Calendar.current.dateInterval(of: .day, for: selectedDate) else { return "-" }
            duration = store.taskFocusDuration(in: interval, finished: finished)
            count = store.taskFocusCount(in: interval, finished: finished)
        case .week:
            duration = store.taskFocusDuration(in: selectedWeekInterval, finished: finished)
            count = store.taskFocusCount(in: selectedWeekInterval, finished: finished)
        case .total:
            let interval = DateInterval(start: .distantPast, end: Date.distantFuture)
            duration = store.taskFocusDuration(in: interval, finished: finished)
            count = store.taskFocusCount(in: interval, finished: finished)
        }
        return "\(StatisticsDurationFormatter.string(from: duration)) · \(count) tasks"
    }

    private var firstActiveText: String {
        guard let firstActiveAt = store.firstActiveAt(on: selectedDate) else { return "-" }
        return StatisticsDateFormatter.time.string(from: firstActiveAt)
    }

    private var lastActiveText: String {
        guard let lastActiveAt = store.lastActiveAt(on: selectedDate) else { return "-" }
        return StatisticsDateFormatter.time.string(from: lastActiveAt)
    }

    private var activeWindowText: String? {
        guard scope == .day else { return nil }
        return "\(firstActiveText) - \(lastActiveText)"
    }

    private var productiveDurationText: String {
        StatisticsDurationFormatter.string(from: productiveDuration)
    }

    private var productiveDuration: TimeInterval {
        switch scope {
        case .day: store.productiveDuration(on: selectedDate)
        case .week: store.productiveDuration(in: selectedWeekInterval)
        case .total: store.productiveDurationTotal
        }
    }

    private var productiveRatio: Double {
        let productiveDuration: TimeInterval
        let trackedDuration: TimeInterval
        switch scope {
        case .day:
            trackedDuration = store.activeDuration(on: selectedDate)
                + store.routineDuration(on: selectedDate)
                + store.meetingDuration(on: selectedDate)
                + store.breakDuration(on: selectedDate)
            productiveDuration = store.productiveDuration(on: selectedDate)
        case .week:
            trackedDuration = store.activeDuration(in: selectedWeekInterval)
                + store.routineDuration(in: selectedWeekInterval)
                + store.meetingDuration(in: selectedWeekInterval)
                + store.breakDuration(in: selectedWeekInterval)
            productiveDuration = store.productiveDuration(in: selectedWeekInterval)
        case .total:
            trackedDuration = store.activeDurationTotal
                + store.routineDurationTotal
                + store.meetingDurationTotal
                + store.breakDurationTotal
            productiveDuration = store.productiveDurationTotal
        }
        guard trackedDuration > 0 else { return 0 }
        return min(max(productiveDuration / trackedDuration, 0), 1)
    }

    private var topMetrics: [StatisticMetric] {
        [
            StatisticMetric(title: "Productive", value: productiveDurationText, systemImage: "bolt", color: Color(nsColor: .systemGreen)),
            StatisticMetric(title: "Tracked", value: trackedDurationText, systemImage: "timer", color: Color(nsColor: .systemPurple)),
            StatisticMetric(title: "Finished", value: "\(finishedCount)", systemImage: "checkmark.seal", color: .accentColor)
        ]
    }

    private var trackedDurationText: String {
        StatisticsDurationFormatter.string(from: trackedDuration)
    }

    private var trackedDuration: TimeInterval {
        activeDuration + routineDuration + meetingDuration + breakDuration
    }

    private var finishedStats: [TaskCompletionStat] {
        switch scope {
        case .day: store.completedTaskStats(on: selectedDate)
        case .week: store.completedTaskStats(in: selectedWeekInterval)
        case .total: store.completedTaskStats
        }
    }

    private var referenceCount: Int {
        switch scope {
        case .day: store.completedTaskStats.count
        case .week: store.completedTaskStats.count
        case .total: store.daysActiveTotal
        }
    }

    private var actionTelemetryTotal: Int {
        store.actionTelemetry.reduce(0) { $0 + $1.count }
    }

    private var averageText: String {
        let average: Double?
        switch scope {
        case .day:
            average = store.averageLoopsToFinish(on: selectedDate)
        case .week:
            average = store.averageLoopsToFinish(in: selectedWeekInterval)
        case .total:
            average = store.averageLoopsToFinish
        }
        guard let average else { return "-" }
        return String(format: "%.1f", average)
    }

    private var dayTitle: String {
        if scope == .week {
            return weekTitle
        }
        if Calendar.current.isDateInToday(selectedDate) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(selectedDate) {
            return "Yesterday"
        }
        return StatisticsDateFormatter.day.string(from: selectedDate)
    }

    private var weekTitle: String {
        let interval = selectedWeekInterval
        let end = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        if Calendar.current.isDate(Date(), equalTo: interval.start, toGranularity: .weekOfYear) {
            return "This Week"
        }
        return "\(StatisticsDateFormatter.shortDay.string(from: interval.start)) - \(StatisticsDateFormatter.shortDay.string(from: end))"
    }

    private var isSelectedPeriodCurrent: Bool {
        switch scope {
        case .day:
            return Calendar.current.isDateInToday(selectedDate)
        case .week:
            return Calendar.current.isDate(Date(), equalTo: selectedDate, toGranularity: .weekOfYear)
        case .total:
            return true
        }
    }

    private var selectedWeekInterval: DateInterval {
        Calendar.current.dateInterval(of: .weekOfYear, for: selectedDate)
            ?? DateInterval(start: selectedDate, duration: 7 * 24 * 60 * 60)
    }

    private var weekSummaryDays: [WeekSummaryDay] {
        let calendar = Calendar.current
        let interval = selectedWeekInterval
        return (0..<7).compactMap { offset in
            guard
                let day = calendar.date(byAdding: .day, value: offset, to: interval.start),
                day < interval.end
            else {
                return nil
            }

            return WeekSummaryDay(
                id: day,
                date: day,
                iterations: store.loopsCompleted(on: day),
                finished: store.tasksFinished(on: day).count,
                breaks: store.breakCount(on: day),
                breakDuration: store.breakDuration(on: day),
                meetings: store.meetingCount(on: day),
                meetingDuration: store.meetingDuration(on: day),
                routines: store.routineCount(on: day),
                routineDuration: store.routineDuration(on: day),
                activeDuration: store.activeDuration(on: day),
                productiveDuration: store.productiveDuration(on: day)
            )
        }
    }

    private func moveSelectedPeriod(by amount: Int) {
        let component: Calendar.Component = scope == .week ? .weekOfYear : .day
        selectedDate = Calendar.current.date(byAdding: component, value: amount, to: selectedDate) ?? selectedDate
    }
}

private enum StatisticsScope: String, CaseIterable, Identifiable {
    case day
    case week
    case total

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .total: "Total"
        }
    }
}

private enum StatisticsMode: String, CaseIterable, Identifiable {
    case summary
    case details

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .details: "Details"
        }
    }
}

private struct StatisticMetric: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var value: String
    var systemImage: String
    var color: Color
}

private struct StatisticsSummaryView: View {
    let metrics: [StatisticMetric]
    let productiveText: String
    let breakText: String
    let meetingText: String
    let routineText: String
    let productiveDuration: TimeInterval
    let breakDuration: TimeInterval
    let meetingDuration: TimeInterval
    let routineDuration: TimeInterval
    let productiveRatio: Double
    let meetingCount: Int
    let breakCount: Int
    let routineCount: Int
    let activeWindowText: String?
    let iterationsCount: Int
    let finishedCount: Int
    let averageText: String
    let finishedStats: [TaskCompletionStat]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(metrics) { metric in
                    TopStatCard(metric: metric)
                }
            }

            TimeBalanceCard(
                productiveText: productiveText,
                breakText: breakText,
                meetingText: meetingText,
                routineText: routineText,
                productiveDuration: productiveDuration,
                breakDuration: breakDuration,
                meetingDuration: meetingDuration,
                routineDuration: routineDuration,
                productiveRatio: productiveRatio
            )

            VStack(spacing: 8) {
                if let activeWindowText {
                    SummaryFactRow(title: "Active window", value: activeWindowText, systemImage: "sun.max")
                }
                SummaryFactRow(title: "Output", value: "\(iterationsCount) loops · \(finishedCount) finished", systemImage: "arrow.triangle.2.circlepath")
                SummaryFactRow(title: "Scheduled", value: "\(routineCount) routines · \(meetingCount) meetings · \(breakCount) breaks", systemImage: "pause.circle")
                SummaryFactRow(title: "Average", value: "\(averageText) iterations / task", systemImage: "chart.bar")
            }

            TaskSection(title: "Finished Tasks", tasks: Array(finishedStats.prefix(5)), emptyTitle: "No finished tasks") { stat in
                CompletedTaskStatRow(stat: stat)
            }
        }
    }
}

private struct TopStatCard: View {
    let metric: StatisticMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: metric.systemImage)
                .font(.title3)
                .foregroundStyle(metric.color)
                .frame(height: 22, alignment: .leading)

            Text(metric.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(metric.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TimeBalanceCard: View {
    let productiveText: String
    let breakText: String
    let meetingText: String
    let routineText: String
    let productiveDuration: TimeInterval
    let breakDuration: TimeInterval
    let meetingDuration: TimeInterval
    let routineDuration: TimeInterval
    let productiveRatio: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Time balance", systemImage: "clock")
                    .font(.callout.weight(.semibold))

                Spacer()

                Text("\(Int(round(productiveRatio * 100)))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            TimeBalanceTrack(
                productiveDuration: productiveDuration,
                routineDuration: routineDuration,
                meetingDuration: meetingDuration,
                breakDuration: breakDuration
            )
            .frame(height: 10)

            HStack(spacing: 10) {
                MiniStatLabel(title: "Productive", value: productiveText, color: Color(nsColor: .systemGreen))
                MiniStatLabel(title: "Routines", value: routineText, color: Color(nsColor: .systemTeal))
                MiniStatLabel(title: "Meetings", value: meetingText, color: Color(nsColor: .systemBlue))
                MiniStatLabel(title: "Breaks", value: breakText, color: Color(nsColor: .systemOrange))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MiniStatLabel: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TimeBalanceTrack: View {
    let productiveDuration: TimeInterval
    let routineDuration: TimeInterval
    let meetingDuration: TimeInterval
    let breakDuration: TimeInterval

    private var totalDuration: TimeInterval {
        productiveDuration + routineDuration + meetingDuration + breakDuration
    }

    private var segments: [TimeBalanceSegment] {
        [
            TimeBalanceSegment(value: productiveDuration, color: Color(nsColor: .systemGreen)),
            TimeBalanceSegment(value: routineDuration, color: Color(nsColor: .systemTeal)),
            TimeBalanceSegment(value: meetingDuration, color: Color(nsColor: .systemBlue)),
            TimeBalanceSegment(value: breakDuration, color: Color(nsColor: .systemOrange))
        ]
        .filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let total = max(totalDuration, 1)
            let resolvedSegments = resolvedSegments(width: width, total: total)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))

                HStack(spacing: 0) {
                    ForEach(resolvedSegments) { segment in
                        Rectangle()
                            .fill(segment.color.opacity(0.9))
                            .frame(width: segment.width, height: height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private func resolvedSegments(width: CGFloat, total: TimeInterval) -> [ResolvedTimeBalanceSegment] {
        var usedWidth: CGFloat = 0
        return segments.compactMap { segment in
            guard usedWidth < width else { return nil }
            let rawWidth = width * CGFloat(min(max(segment.value / total, 0), 1))
            let segmentWidth = min(rawWidth, width - usedWidth)
            guard segmentWidth > 0 else { return nil }
            usedWidth += segmentWidth
            return ResolvedTimeBalanceSegment(width: segmentWidth, color: segment.color)
        }
    }
}

private struct TimeBalanceSegment {
    let value: TimeInterval
    let color: Color
}

private struct ResolvedTimeBalanceSegment: Identifiable {
    let id = UUID()
    let width: CGFloat
    let color: Color
}

private struct SummaryFactRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.callout.weight(.medium))

            Spacer()

            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WeekSummaryDay: Identifiable, Equatable {
    var id: Date
    var date: Date
    var iterations: Int
    var finished: Int
    var breaks: Int
    var breakDuration: TimeInterval
    var meetings: Int
    var meetingDuration: TimeInterval
    var routines: Int
    var routineDuration: TimeInterval
    var activeDuration: TimeInterval
    var productiveDuration: TimeInterval
}

private struct WeekSummaryView: View {
    let days: [WeekSummaryDay]
    let style: WeekSummaryStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Week Summary")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            WeekChartCard(
                title: "Productivity",
                legend: [
                    WeekChartLegendItem(title: "Active", color: Color(nsColor: .systemPurple)),
                    WeekChartLegendItem(title: "Productive", color: Color(nsColor: .systemGreen))
                ]
            ) {
                ProductiveWeekChart(days: days)
            }

            if style == .full {
                WeekChartCard(
                    title: "Output",
                    legend: [
                        WeekChartLegendItem(title: "Loops", color: .accentColor),
                        WeekChartLegendItem(title: "Finished", color: Color(nsColor: .systemGreen))
                    ]
                ) {
                    WorkWeekChart(days: days)
                }

                WeekChartCard(
                    title: "Breaks",
                    legend: [
                        WeekChartLegendItem(title: "Time", color: Color(nsColor: .systemOrange)),
                        WeekChartLegendItem(title: "Count", color: .secondary)
                    ]
                ) {
                    BreakWeekChart(days: days)
                }

                WeekChartCard(
                    title: "Meetings",
                    legend: [
                        WeekChartLegendItem(title: "Time", color: Color(nsColor: .systemBlue)),
                        WeekChartLegendItem(title: "Count", color: .secondary)
                    ]
                ) {
                    MeetingWeekChart(days: days)
                }
            }
        }
    }
}

private enum WeekSummaryStyle {
    case productivity
    case full
}

private struct WeekChartLegendItem: Identifiable {
    var id: String { title }
    var title: String
    var color: Color
}

private struct WeekChartCard<Content: View>: View {
    let title: String
    let legend: [WeekChartLegendItem]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.callout.weight(.semibold))

                Spacer()

                HStack(spacing: 8) {
                    ForEach(legend) { item in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 7, height: 7)
                            Text(item.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            content
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WorkWeekChart: View {
    let days: [WeekSummaryDay]

    private var maxValue: Int {
        max(1, days.map { $0.iterations }.max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(days) { day in
                HStack(spacing: 10) {
                    dayLabel(for: day)

                    ProgressTrack(
                        value: Double(day.iterations),
                        maxValue: Double(maxValue),
                        color: .accentColor
                    )

                    Text("\(day.iterations)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(nsColor: .systemGreen))
                            .frame(width: 7, height: 7)
                        Text("\(day.finished)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 34, alignment: .trailing)
                }
                .loopHelp("\(day.iterations) loops, \(day.finished) finished")
            }
        }
    }

    private func dayLabel(for day: WeekSummaryDay) -> some View {
        Text(StatisticsDateFormatter.weekday.string(from: day.date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, alignment: .leading)
    }
}

private struct BreakWeekChart: View {
    let days: [WeekSummaryDay]

    private var maxMinutes: Int {
        max(1, days.map { breakMinutes(for: $0) }.max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(days) { day in
                HStack(spacing: 10) {
                    dayLabel(for: day)

                    ProgressTrack(
                        value: Double(breakMinutes(for: day)),
                        maxValue: Double(maxMinutes),
                        color: Color(nsColor: .systemOrange)
                    )

                    Text(StatisticsDurationFormatter.string(from: day.breakDuration))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 7, height: 7)
                        Text("\(day.breaks)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 34, alignment: .trailing)
                }
                .loopHelp("\(day.breaks) breaks, \(StatisticsDurationFormatter.string(from: day.breakDuration))")
            }
        }
    }

    private func breakMinutes(for day: WeekSummaryDay) -> Int {
        Int(ceil(day.breakDuration / 60))
    }

    private func dayLabel(for day: WeekSummaryDay) -> some View {
        Text(StatisticsDateFormatter.weekday.string(from: day.date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, alignment: .leading)
    }
}

private struct MeetingWeekChart: View {
    let days: [WeekSummaryDay]

    private var maxMinutes: Int {
        max(1, days.map { meetingMinutes(for: $0) }.max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(days) { day in
                HStack(spacing: 10) {
                    dayLabel(for: day)

                    ProgressTrack(
                        value: Double(meetingMinutes(for: day)),
                        maxValue: Double(maxMinutes),
                        color: Color(nsColor: .systemBlue)
                    )

                    Text(StatisticsDurationFormatter.string(from: day.meetingDuration))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 7, height: 7)
                        Text("\(day.meetings)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 34, alignment: .trailing)
                }
                .loopHelp("\(day.meetings) meetings, \(StatisticsDurationFormatter.string(from: day.meetingDuration))")
            }
        }
    }

    private func meetingMinutes(for day: WeekSummaryDay) -> Int {
        Int(ceil(day.meetingDuration / 60))
    }

    private func dayLabel(for day: WeekSummaryDay) -> some View {
        Text(StatisticsDateFormatter.weekday.string(from: day.date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, alignment: .leading)
    }
}

private struct ProductiveWeekChart: View {
    let days: [WeekSummaryDay]

    private var maxMinutes: Int {
        max(1, days.map { activeMinutes(for: $0) }.max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(days) { day in
                HStack(spacing: 10) {
                    dayLabel(for: day)

                    ProgressTrack(
                        value: Double(activeMinutes(for: day)),
                        maxValue: Double(maxMinutes),
                        color: Color(nsColor: .systemPurple)
                    )

                    Text(StatisticsDurationFormatter.string(from: day.activeDuration))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(nsColor: .systemGreen))
                            .frame(width: 7, height: 7)
                        Text(StatisticsDurationFormatter.string(from: day.productiveDuration))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 62, alignment: .trailing)
                }
                .loopHelp("\(StatisticsDurationFormatter.string(from: day.productiveDuration)) productive of \(StatisticsDurationFormatter.string(from: day.activeDuration)) active")
            }
        }
    }

    private func activeMinutes(for day: WeekSummaryDay) -> Int {
        Int(ceil(day.activeDuration / 60))
    }

    private func dayLabel(for day: WeekSummaryDay) -> some View {
        Text(StatisticsDateFormatter.weekday.string(from: day.date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, alignment: .leading)
    }
}

private struct ProgressTrack: View {
    let value: Double
    let maxValue: Double
    let color: Color

    private var ratio: Double {
        guard maxValue > 0 else { return 0 }
        return min(max(value / maxValue, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))

                if value > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(color.opacity(0.85))
                        .frame(width: max(8, proxy.size.width * ratio))
                }
            }
        }
        .frame(height: 9)
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

private struct ActionTelemetryDashboard: View {
    let stats: [ActionTelemetryStat]

    @State private var selectedCategory: ActionTelemetryCategory = .all
    @State private var searchText = ""
    @State private var showUsedOnly = true

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 10) {
                StatTile(title: "Total actions", value: "\(totalCount)", systemImage: "sum")
                StatTile(title: "Tracked actions", value: "\(usedActionCount)", systemImage: "number")
                StatTile(title: "Top action", value: topActionText, systemImage: "chart.bar.fill")
            }

            HStack(spacing: 8) {
                Picker("", selection: $selectedCategory) {
                    ForEach(ActionTelemetryCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Used only", isOn: $showUsedOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }

            TextField("Filter actions", text: $searchText)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                if filteredStats.isEmpty {
                    Text("No matching actions")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ForEach(filteredStats) { stat in
                        ActionTelemetryRow(stat: stat, maxCount: maxFilteredCount)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var filteredStats: [ActionTelemetryStat] {
        stats.filter { stat in
            let matchesCategory = selectedCategory == .all || stat.category == selectedCategory
            let matchesUsage = !showUsedOnly || stat.count > 0
            let matchesSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || stat.title.localizedCaseInsensitiveContains(searchText)
            return matchesCategory && matchesUsage && matchesSearch
        }
    }

    private var maxFilteredCount: Int {
        max(filteredStats.map(\.count).max() ?? 0, 1)
    }

    private var totalCount: Int {
        stats.reduce(0) { $0 + $1.count }
    }

    private var usedActionCount: Int {
        stats.filter { $0.count > 0 }.count
    }

    private var topActionText: String {
        guard let topStat = stats.max(by: { $0.count < $1.count }), topStat.count > 0 else { return "-" }
        return "\(topStat.count)"
    }
}

private struct ActionTelemetryRow: View {
    let stat: ActionTelemetryStat
    let maxCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: stat.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Text(stat.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Spacer()

                Text("\(stat.count)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(stat.count > 0 ? .primary : .secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))

                    if stat.count > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor.opacity(0.72))
                            .frame(width: max(8, proxy.size.width * CGFloat(stat.count) / CGFloat(maxCount)))
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CompletedTaskStatRow: View {
    @EnvironmentObject private var store: TaskStore

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
        .contextMenu {
            if let task = store.tasks.first(where: { $0.id == stat.id }) {
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
}

private enum StatisticsDateFormatter {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let shortDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum StatisticsDurationFormatter {
    static let compact: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropAll]
        return formatter
    }()

    static func string(from duration: TimeInterval) -> String {
        compact.string(from: max(0, duration)) ?? "0m"
    }
}

private struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoutineBlock
    @State private var scheduleHour = 10
    @State private var scheduleMinute = 0

    private let isNew: Bool
    let onChooseApplication: () -> LinkedApp?
    let onSave: (RoutineBlock) -> Void

    init(routine: RoutineBlock?, onChooseApplication: @escaping () -> LinkedApp?, onSave: @escaping (RoutineBlock) -> Void) {
        _draft = State(initialValue: routine ?? RoutineBlock(title: ""))
        let firstScheduleTime = routine?.scheduleTimes.sorted().first
        _scheduleHour = State(initialValue: firstScheduleTime?.hour ?? 10)
        _scheduleMinute = State(initialValue: firstScheduleTime?.minute ?? 0)
        self.isNew = routine == nil
        self.onChooseApplication = onChooseApplication
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isNew ? "New Routine" : "Routine Details")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            routineEditorSection("Title") {
                TextField("Routine name", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            routineEditorSection("Application") {
                HStack(spacing: 8) {
                    Label(draft.linkedApp?.name ?? "No app selected", systemImage: "app.dashed")
                        .lineLimit(1)
                        .foregroundStyle(draft.linkedApp == nil ? .secondary : .primary)

                    Spacer()

                    if draft.linkedApp != nil {
                        Button {
                            draft.linkedApp = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .loopHelp("Clear selected app")
                    }

                    Button("Choose") {
                        chooseApplication()
                    }
                }

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
            }

            routineEditorSection("Cadence") {
                Stepper(value: routineCadenceBinding, in: 1...LoopCadence.maxLoops, step: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: "repeat")
                            .foregroundStyle(.secondary)
                        Text(draft.cadence.title)
                            .monospacedDigit()
                    }
                }
            }

            routineEditorSection("Time block") {
                Stepper(value: $draft.durationMinutes, in: 1...240, step: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .foregroundStyle(.secondary)
                        Text("\(draft.durationMinutes) \(draft.durationMinutes == 1 ? "minute" : "minutes")")
                            .monospacedDigit()
                    }
                }
            }

            routineEditorSection("Schedule") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Stepper(value: $scheduleHour, in: 0...23, step: 1) {
                            Text(String(format: "%02d", scheduleHour))
                                .monospacedDigit()
                                .frame(width: 26, alignment: .leading)
                        }
                        .frame(width: 112)

                        Stepper(value: $scheduleMinute, in: 0...59, step: 5) {
                            Text(String(format: "%02d", scheduleMinute))
                                .monospacedDigit()
                                .frame(width: 26, alignment: .leading)
                        }
                        .frame(width: 112)

                        Button {
                            addScheduleTime(hour: scheduleHour, minute: scheduleMinute)
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }

                    HStack(spacing: 8) {
                        Button("10:00") {
                            addScheduleTime(hour: 10, minute: 0)
                        }
                        .controlSize(.small)

                        Button("14:00") {
                            addScheduleTime(hour: 14, minute: 0)
                        }
                        .controlSize(.small)

                        Button("Clear") {
                            draft.scheduleTimes = []
                            draft.lastCompletedScheduledAt = nil
                        }
                        .controlSize(.small)
                        .disabled(draft.scheduleTimes.isEmpty)
                    }

                    if !draft.scheduleTimes.isEmpty {
                        LazyVGrid(columns: scheduleColumns, alignment: .leading, spacing: 6) {
                            ForEach(draft.scheduleTimes.sorted()) { scheduleTime in
                                HStack(spacing: 5) {
                                    Text(String(format: "%02d:%02d", scheduleTime.hour, scheduleTime.minute))
                                        .monospacedDigit()
                                    Button {
                                        removeScheduleTime(scheduleTime)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.plain)
                                    .loopHelp("Remove time")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enabled", isOn: $draft.isEnabled)
                    .toggleStyle(.checkbox)
                Toggle("Counts as productive time", isOn: $draft.countsAsProductive)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onSubmit(save)
    }

    private func save() {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.durationMinutes = min(max(draft.durationMinutes, 1), 240)
        draft.scheduleTimes = Array(Set(draft.scheduleTimes)).sorted()
        onSave(draft)
        dismiss()
    }

    private func chooseApplication() {
        if let linkedApp = onChooseApplication() {
            draft.linkedApp = linkedApp
        }
    }

    private func routineEditorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
        }
    }

    private var popularApplicationColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
    }

    private var scheduleColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 78), spacing: 6)
        ]
    }

    private var routineCadenceBinding: Binding<Int> {
        Binding(
            get: {
                draft.cadence.rawValue
            },
            set: { cadence in
                draft.cadence = LoopCadence(rawValue: cadence)
            }
        )
    }

    private func addScheduleTime(hour: Int, minute: Int) {
        let scheduleTime = DailyScheduleTime(hour: hour, minute: minute)
        if !draft.scheduleTimes.contains(scheduleTime) {
            draft.scheduleTimes.append(scheduleTime)
            draft.scheduleTimes.sort()
            draft.lastCompletedScheduledAt = nil
        }
    }

    private func removeScheduleTime(_ scheduleTime: DailyScheduleTime) {
        draft.scheduleTimes.removeAll { $0 == scheduleTime }
        draft.lastCompletedScheduledAt = nil
    }
}

private struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: TaskStore

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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isNew ? "New Task" : "Task Details")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            taskEditorSection("Title") {
                TextField("Task name", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            taskEditorSection("Application") {
                HStack(spacing: 8) {
                    Label(draft.linkedApp?.name ?? "No app selected", systemImage: "app.dashed")
                        .lineLimit(1)
                        .foregroundStyle(draft.linkedApp == nil ? .secondary : .primary)

                    Spacer()

                    if draft.linkedApp != nil {
                        Button {
                            draft.linkedApp = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .loopHelp("Clear selected app")
                    }

                    Button("Choose") {
                        chooseApplication()
                    }
                }

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
            }

            taskEditorSection("Cadence") {
                Stepper(value: taskCadenceBinding, in: 1...LoopCadence.maxLoops, step: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: "repeat")
                            .foregroundStyle(.secondary)
                        Text(draft.cadence.title)
                            .monospacedDigit()
                    }
                }
            }

            taskEditorSection("Iteration timer") {
                Stepper(value: iterationTimerMinutesBinding, in: 0...240, step: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .foregroundStyle(.secondary)
                        Text(iterationTimerText)
                            .monospacedDigit()
                    }
                }
            }

            taskEditorSection("Schedule") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Scheduled", isOn: scheduledTaskBinding)
                        .toggleStyle(.checkbox)

                    if draft.scheduledFor != nil {
                        DatePicker(
                            "Time",
                            selection: scheduledForBinding,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()

                        HStack(spacing: 8) {
                            Button("Tomorrow 09:00") {
                                draft.scheduledFor = scheduledDate(daysFromToday: 1, hour: 9, minute: 0)
                            }
                            .controlSize(.small)

                            Button("Today 10:00") {
                                draft.scheduledFor = scheduledDate(daysFromToday: 0, hour: 10, minute: 0)
                            }
                            .controlSize(.small)

                            Button("Today 14:00") {
                                draft.scheduledFor = scheduledDate(daysFromToday: 0, hour: 14, minute: 0)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onSubmit(save)
        .onAppear {
            if isNew && draft.iterationTimerMinutes == nil {
                draft.iterationTimerMinutes = store.defaultIterationTimerMinutesOrNil
            }
        }
    }

    private func save() {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(draft)
        dismiss()
    }

    private func chooseApplication() {
        if let linkedApp = onChooseApplication() {
            draft.linkedApp = linkedApp
        }
    }

    private func taskEditorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
        }
    }

    private var iterationTimerText: String {
        guard let minutes = draft.iterationTimerMinutes else { return "0 minutes" }
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    private var scheduledTaskBinding: Binding<Bool> {
        Binding(
            get: {
                draft.scheduledFor != nil
            },
            set: { isScheduled in
                if isScheduled {
                    draft.scheduledFor = draft.scheduledFor ?? scheduledDate(daysFromToday: 1, hour: 9, minute: 0)
                } else {
                    draft.scheduledFor = nil
                }
            }
        )
    }

    private var scheduledForBinding: Binding<Date> {
        Binding(
            get: {
                draft.scheduledFor ?? scheduledDate(daysFromToday: 1, hour: 9, minute: 0)
            },
            set: { date in
                draft.scheduledFor = date
            }
        )
    }

    private var iterationTimerMinutesBinding: Binding<Int> {
        Binding(
            get: {
                draft.iterationTimerMinutes ?? 0
            },
            set: { minutes in
                let clampedMinutes = min(max(minutes, 0), 240)
                draft.iterationTimerMinutes = clampedMinutes == 0 ? nil : clampedMinutes
                draft.iterationTimerStartedAt = nil
                draft.iterationTimerStartedLoop = nil
            }
        )
    }

    private var taskCadenceBinding: Binding<Int> {
        Binding(
            get: {
                draft.cadence.rawValue
            },
            set: { cadence in
                draft.cadence = LoopCadence(rawValue: cadence)
            }
        )
    }

    private var popularApplicationColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
    }

    private func scheduledDate(daysFromToday: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let targetDay = calendar.date(byAdding: .day, value: daysFromToday, to: startOfDay) ?? startOfDay
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: targetDay) ?? targetDay
    }
}

private enum PopularApplication: String, CaseIterable, Identifiable {
    case chatGPT
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
        case .chatGPT:
            LinkedApp(
                name: "ChatGPT",
                bundleIdentifier: "com.openai.chat",
                path: "/Applications/ChatGPT.app"
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
                    title: "Complete current item",
                    shortcut: store.doneShortcut,
                    onRecord: store.applyDoneShortcut
                )

                shortcutRecorder(
                    title: "Quick add to Inbox",
                    shortcut: store.quickAddShortcut,
                    onRecord: store.applyQuickAddShortcut
                )

                shortcutRecorder(
                    title: "Break",
                    shortcut: store.breakShortcut,
                    onRecord: store.applyBreakShortcut
                )
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
