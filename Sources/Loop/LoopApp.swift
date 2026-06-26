import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct LoopMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private enum HotKeyIdentifier {
    static let togglePopover = UInt32(1)
    static let markFocusedTaskDone = UInt32(2)
    static let quickAddTask = UInt32(3)
    static let startBreak = UInt32(4)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TaskStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private var globalMouseDownMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var isChoosingApplication = false
    private var focusBannerWindow: NSPanel?
    private var focusBannerDismissWorkItem: DispatchWorkItem?
    private var timerExpirationContext: TimerExpirationContext?
    private var nextTimerExpirationBannerAt: Date?
    private var breakExpirationContext: BreakExpirationContext?
    private var quickAddWindow: NSPanel?
    private var quickAddDraft = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        configureHotKey()
        configureNotifications()
        configureOutsideClickHandling()
        configureStatusTitleUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
        }
        dismissFocusBanner()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        if let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Loop") {
            image.isTemplate = true
            button.image = image
        }
        button.title = ""
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItemTitle()
    }

    private func configurePopover() {
        let rootView = LoopPanelView(
            onQuit: { NSApp.terminate(nil) },
            onChooseApplication: { [weak self] in
                self?.chooseApplication()
            }
        )
        .environmentObject(store)

        popover.contentSize = NSSize(width: 420, height: 540)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    private func configureHotKey() {
        hotKeyManager = HotKeyManager()
        hotKeyManager?.onRegistrationError = { [weak store] message in
            DispatchQueue.main.async {
                store?.notice = message
            }
        }
        registerPopoverHotKey(store.shortcut)
        registerDoneHotKey(store.doneShortcut)
        registerQuickAddHotKey(store.quickAddShortcut)
        registerBreakHotKey(store.breakShortcut)
        store.onShortcutChange = { [weak self] shortcut in
            self?.registerPopoverHotKey(shortcut)
        }
        store.onDoneShortcutChange = { [weak self] shortcut in
            self?.registerDoneHotKey(shortcut)
        }
        store.onQuickAddShortcutChange = { [weak self] shortcut in
            self?.registerQuickAddHotKey(shortcut)
        }
        store.onBreakShortcutChange = { [weak self] shortcut in
            self?.registerBreakHotKey(shortcut)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.showPopover()
        }
    }

    private func registerPopoverHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.togglePopover) { [weak self] in
            self?.togglePopover(nil)
        }
    }

    private func registerDoneHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.markFocusedTaskDone) { [weak self] in
            guard let self else { return }
            if self.store.markFocusedTaskDone(openNextFocusedApp: true) {
                self.showFocusBanner()
            }
        }
    }

    private func registerQuickAddHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.quickAddTask) { [weak self] in
            self?.showQuickAddWindow()
        }
    }

    private func registerBreakHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.startBreak) { [weak self] in
            guard let self else { return }
            if self.store.isOnBreak {
                self.store.endBreak()
            } else {
                self.store.startBreak()
            }
        }
    }

    private func configureNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverFromNotification),
            name: .loopShouldClosePopover,
            object: nil
        )
    }

    private func configureOutsideClickHandling() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopover()
            }
        }
    }

    private func configureStatusTitleUpdates() {
        store.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemTitle()
                    self?.evaluateTimerExpirationBanner()
                    self?.evaluateBreakExpirationBanner()
                }
            }
            .store(in: &cancellables)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !isChoosingApplication else { return }
        closePopover()
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusItemMenu()
        } else {
            togglePopover(sender)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    @objc private func closePopoverFromNotification(_ notification: Notification) {
        closePopover()
    }

    private func closePopover() {
        guard !isChoosingApplication else { return }
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func showStatusItemMenu() {
        closePopover()
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        let appNameItem = NSMenuItem(title: appDisplayName, action: nil, keyEquivalent: "")
        appNameItem.isEnabled = false
        menu.addItem(appNameItem)

        menu.popUp(positioning: appNameItem, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Loop"
    }

    private func chooseApplication() -> LinkedApp? {
        isChoosingApplication = true
        let previousBehavior = popover.behavior
        popover.behavior = .applicationDefined
        defer {
            popover.behavior = previousBehavior
            isChoosingApplication = false
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle, .application]

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let bundle = Bundle(url: url)
        return LinkedApp(
            name: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundle?.bundleIdentifier,
            path: url.path
        )
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }
        let title = store.breakTimerText ?? menuBarTitle(taskTitle: store.focusedTaskTitle, timerText: store.focusedTaskTimerText)
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = store.breakTimerText ?? menuBarTooltip(taskTitle: store.focusedTaskTitle, timerText: store.focusedTaskTimerText)
    }

    private func truncatedMenuBarTitle(_ title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTitle.isEmpty else { return "" }
        guard trimmedTitle.count > 34 else { return trimmedTitle }
        return "\(trimmedTitle.prefix(31))..."
    }

    private func menuBarTitle(taskTitle: String?, timerText: String?) -> String {
        let title = truncatedMenuBarTitle(taskTitle)
        guard let timerText else { return title }
        guard !title.isEmpty else { return timerText }
        return "\(title) · \(timerText)"
    }

    private func menuBarTooltip(taskTitle: String?, timerText: String?) -> String {
        let trimmedTitle = taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTitle.isEmpty ? "Open" : trimmedTitle
        guard let timerText else { return title }
        return "\(title) · \(timerText) left"
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showQuickAddWindow() {
        NSApp.activate(ignoringOtherApps: true)

        let panelSize = NSSize(width: 380, height: 62)
        let panel = quickAddWindow ?? QuickAddPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setContentSize(panelSize)
        panel.contentView = NSHostingView(rootView: QuickAddTaskView(
            store: store,
            initialTitle: quickAddDraft,
            onDraftChange: { [weak self] draft in
                self?.quickAddDraft = draft
            },
            onDismiss: { [weak self] in
                self?.quickAddWindow?.close()
            }
        ))
        panel.center()

        quickAddWindow = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            guard let textField = panel.contentView?.firstSubview(ofType: KeyHandlingTextField.self) else { return }
            panel.makeFirstResponder(textField)
        }
    }

    private func showFocusBanner() {
        let bannerState = FocusBannerState(task: store.focusedTask)
        showBanner(state: bannerState) { [weak self] in
            guard let self else { return }
            if let focusedTask = self.store.focusedTask {
                self.store.openLinkedApp(for: focusedTask)
            }
            self.dismissFocusBanner()
        }
    }

    private func evaluateTimerExpirationBanner() {
        guard
            let focusedTask = store.focusedTask,
            focusedTask.iterationTimerStartedLoop == store.loopNumber,
            let startedAt = focusedTask.iterationTimerStartedAt,
            let remainingSeconds = store.iterationTimerRemainingSeconds(for: focusedTask),
            remainingSeconds <= 0
        else {
            resetTimerExpirationReminder()
            return
        }

        let context = TimerExpirationContext(taskID: focusedTask.id, startedAt: startedAt)
        if timerExpirationContext != context {
            timerExpirationContext = context
            nextTimerExpirationBannerAt = Date()
        }

        let now = Date()
        guard nextTimerExpirationBannerAt.map({ now >= $0 }) ?? true else { return }

        showTimerExpiredBanner(for: focusedTask)
        nextTimerExpirationBannerAt = now.addingTimeInterval(60)
    }

    private func resetTimerExpirationReminder() {
        timerExpirationContext = nil
        nextTimerExpirationBannerAt = nil
    }

    private func showTimerExpiredBanner(for task: LoopTask) {
        showBanner(
            state: FocusBannerState(
                title: "Time is up",
                subtitle: task.title,
                systemImage: "timer"
            ),
            onClick: {}
        )
    }

    private func evaluateBreakExpirationBanner() {
        guard
            store.isOnBreak,
            store.isBreakTimeUp,
            let breakStartedAt = store.breakStartedAt,
            let breakUntil = store.breakUntil
        else {
            breakExpirationContext = nil
            return
        }

        let context = BreakExpirationContext(startedAt: breakStartedAt, until: breakUntil)
        guard breakExpirationContext != context else { return }

        breakExpirationContext = context
        showBreakExpiredBanner()
    }

    private func showBreakExpiredBanner() {
        showBanner(
            state: FocusBannerState(
                title: "Break is over",
                subtitle: "End break when you are ready",
                systemImage: "cup.and.saucer.fill"
            ),
            onClick: {}
        )
    }

    private func showBanner(state: FocusBannerState, onClick: @escaping () -> Void) {
        let bannerView = FocusBannerView(state: state, onClick: onClick)

        let bannerSize = NSSize(width: 390, height: 78)
        let panel = focusBannerWindow ?? NSPanel(
            contentRect: NSRect(origin: .zero, size: bannerSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: bannerView)
        panel.setContentSize(bannerSize)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        panel.setFrame(focusBannerFrame(size: bannerSize), display: true)

        focusBannerWindow = panel
        panel.orderFrontRegardless()

        focusBannerDismissWorkItem?.cancel()
        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.dismissFocusBanner()
        }
        focusBannerDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.7, execute: dismissWorkItem)
    }

    private func focusBannerFrame(size: NSSize) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let x = visibleFrame.midX - (size.width / 2)
        let y = visibleFrame.maxY - size.height - 128
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func dismissFocusBanner() {
        focusBannerDismissWorkItem?.cancel()
        focusBannerDismissWorkItem = nil
        focusBannerWindow?.close()
        focusBannerWindow = nil
    }
}

private struct QuickAddTaskView: View {
    @ObservedObject var store: TaskStore
    let initialTitle: String
    let onDraftChange: (String) -> Void
    let onDismiss: () -> Void

    @State private var title = ""

    init(
        store: TaskStore,
        initialTitle: String,
        onDraftChange: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.initialTitle = initialTitle
        self.onDraftChange = onDraftChange
        self.onDismiss = onDismiss
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            ReturnAwareTextField(
                placeholder: "Add task to backlog",
                text: $title,
                onReturn: { currentTitle in
                    submit(currentTitle, addToIteration: false)
                },
                onCommandReturn: { currentTitle in
                    submit(currentTitle, addToIteration: true)
                },
                onTextChange: { currentTitle in
                    title = currentTitle
                    onDraftChange(currentTitle)
                },
                onEscape: onDismiss
            )
            .frame(height: 34)
        }
        .padding(.horizontal, 14)
        .frame(width: 380, height: 62)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func submit(_ currentTitle: String, addToIteration: Bool) {
        let trimmedTitle = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        store.addTask(title: trimmedTitle, addToIteration: addToIteration)
        title = ""
        onDraftChange("")
        onDismiss()
    }
}

private struct ReturnAwareTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onReturn: (String) -> Void
    let onCommandReturn: (String) -> Void
    let onTextChange: (String) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyHandlingTextField {
        let textField = KeyHandlingTextField()
        textField.placeholderString = placeholder
        textField.bezelStyle = .roundedBezel
        textField.isBordered = true
        textField.drawsBackground = true
        textField.font = .systemFont(ofSize: 18, weight: .regular)
        textField.delegate = context.coordinator
        textField.onEscape = onEscape
        textField.onCommandReturn = onCommandReturn
        context.coordinator.onReturn = onReturn
        context.coordinator.onCommandReturn = onCommandReturn
        context.coordinator.onTextChange = onTextChange

        return textField
    }

    func updateNSView(_ nsView: KeyHandlingTextField, context: Context) {
        nsView.stringValue = text
        nsView.placeholderString = placeholder
        nsView.onEscape = onEscape
        nsView.onCommandReturn = onCommandReturn
        context.coordinator.onReturn = onReturn
        context.coordinator.onCommandReturn = onCommandReturn
        context.coordinator.onTextChange = onTextChange
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

private final class KeyHandlingTextField: NSTextField {
    var onEscape: (() -> Void)?
    var onCommandReturn: ((String) -> Void)?
    private var didRequestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didRequestInitialFocus else { return }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 else {
            return super.performKeyEquivalent(with: event)
        }

        onCommandReturn?(currentEditor()?.string ?? stringValue)
        return true
    }
}

private final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSView {
    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let typedSelf = self as? T {
            return typedSelf
        }

        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) {
                return match
            }
        }

        return nil
    }
}

private struct TimerExpirationContext: Equatable {
    let taskID: UUID
    let startedAt: Date
}

private struct BreakExpirationContext: Equatable {
    let startedAt: Date
    let until: Date
}

private struct FocusBannerState {
    let title: String
    let subtitle: String
    let systemImage: String
    let isClickable: Bool

    init(title: String, subtitle: String, systemImage: String, isClickable: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isClickable = isClickable
    }

    init(task: LoopTask?) {
        if let task {
            title = "Focus"
            subtitle = [
                task.title,
                task.linkedApp?.name
            ]
            .compactMap { value in
                let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedValue?.isEmpty == false ? trimmedValue : nil
            }
            .joined(separator: " · ")
            systemImage = "scope"
            isClickable = task.linkedApp != nil
        } else {
            title = "Iteration complete"
            subtitle = "No task is waiting"
            systemImage = "checkmark.circle.fill"
            isClickable = false
        }
    }
}

private struct FocusBannerView: View {
    let state: FocusBannerState
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 5, height: 50)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: state.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .textCase(.uppercase)
                Text(state.subtitle)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Color.black.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if state.isClickable {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.42))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 390, height: 78)
        .background(Color(red: 0.97, green: 0.98, blue: 0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            if state.isClickable {
                onClick()
            }
        }
    }
}
