import AppKit
import Combine
import CoreGraphics
import Darwin
import SwiftUI
import UniformTypeIdentifiers

private final class SingleInstanceLock {
    private let fileDescriptor: Int32

    init?(bundleIdentifier: String) {
        let safeIdentifier = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeIdentifier).instance.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        fileDescriptor = descriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}

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
    private lazy var store = TaskStore()
    private let meetingMonitor = MeetingMonitor()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private var globalMouseDownMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var focusBannerWindow: NSPanel?
    private var focusBannerDismissWorkItem: DispatchWorkItem?
    private var timerExpirationContext: TimerExpirationContext?
    private var nextTimerExpirationBannerAt: Date?
    private var quickAddWindow: NSPanel?
    private var quickAddDraft = ""
    private var quickAddShouldReturnToBackground = false
    private var taskManagerWindow: NSWindow?
    private var morningPlanWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var instanceLock: SingleInstanceLock?
    private var activityGate = InteractiveActivityGate(
        powerAwake: true,
        screenAwake: false,
        sessionActive: false
    )
    private var didFinishLaunching = false
    private var trackingIsInteractive = false
    private var isAwaitingInitialMeetingEvaluation = false
    private var deferredTaskFocusBannerID: UUID?

    func applicationWillFinishLaunching(_ notification: Notification) {
        instanceLock = SingleInstanceLock(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.marekszkudelski.loop")
        if instanceLock == nil {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceLock != nil else { return }
        NSApp.setActivationPolicy(.regular)
        configureStatusItem()
        configurePopover()
        configureHotKey()
        configureNotifications()
        configureOutsideClickHandling()
        configureMeetingMonitor()
        configureTrackingLifecycle()
        configureStatusTitleUpdates()
        activityGate = InteractiveActivityGate(
            powerAwake: true,
            screenAwake: Self.mainDisplayIsAwake,
            sessionActive: Self.currentSessionIsActive
        )
        didFinishLaunching = true
        reconcileInteractiveTracking()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard instanceLock != nil else { return }
        store.suspendTracking()
        store.flushPendingSave()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
        }
        meetingMonitor.stop()
        dismissFocusBanner()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        noteInteractiveActivity()
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
        let rootView = TrayPanelView(
            onPrimaryAction: { [weak self] in
                self?.performTrayPrimaryAction()
            },
            onSelectTask: { [weak self] task in
                guard let self else { return }
                if self.store.isMorningRoutineRequired {
                    self.showMorningPlanWindow()
                } else {
                    self.store.focus(task)
                    self.closePopover()
                }
            },
            onEditTask: { [weak self] task in
                self?.showTaskEditor(task)
            },
            onSelectRoutine: { [weak self] routine in
                self?.store.startRoutineBlock(routine)
                self?.closePopover()
            },
            onEditRoutine: { [weak self] routine in
                self?.showRoutineEditor(routine)
            },
            onOpenTaskManager: { [weak self] in
                self?.showTaskManagerWindow()
            },
            onOpenMorningPlan: { [weak self] in
                self?.showMorningPlanWindow()
            },
            onOpenSettings: { [weak self] in
                self?.showSettingsWindow(initialSection: .general)
            },
            onOpenStats: { [weak self] in
                self?.showSettingsWindow(initialSection: .stats)
            }
        )
        .environmentObject(store)

        popover.contentSize = NSSize(width: 360, height: 310)
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

    }

    private func registerPopoverHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.togglePopover) { [weak self] in
            self?.noteInteractiveActivity()
            self?.togglePopover(nil)
        }
    }

    private func registerDoneHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.markFocusedTaskDone) { [weak self] in
            self?.noteInteractiveActivity()
            self?.completeCurrentFocus()
        }
    }

    private func registerQuickAddHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.quickAddTask) { [weak self] in
            self?.noteInteractiveActivity()
            self?.showQuickAddWindow()
        }
    }

    private func registerBreakHotKey(_ shortcut: KeyboardShortcutSetting) {
        _ = hotKeyManager?.register(shortcut, id: HotKeyIdentifier.startBreak) { [weak self] in
            guard let self else { return }
            self.noteInteractiveActivity()
            if self.store.isOnBreak {
                self.store.endBreak()
            } else {
                self.requestBreak()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFocusModeDidEnd),
            name: .loopFocusModeDidEnd,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFocusDidStart),
            name: .loopFocusDidStart,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleWorkspaceWillSleep(_ notification: Notification) {
        activityGate.systemWillSleep()
        reconcileInteractiveTracking()
    }

    @objc private func handleWorkspaceDidWake(_ notification: Notification) {
        activityGate.systemDidWake()
        store.noteSystemWake()
    }

    @objc private func handleScreensDidSleep(_ notification: Notification) {
        activityGate.screenDidSleep()
        reconcileInteractiveTracking()
    }

    @objc private func handleScreensDidWake(_ notification: Notification) {
        activityGate.screenDidWake()
        activityGate.sessionActive = Self.currentSessionIsActive
        reconcileInteractiveTracking()
    }

    @objc private func handleSessionDidResignActive(_ notification: Notification) {
        activityGate.sessionDidResign()
        reconcileInteractiveTracking()
    }

    @objc private func handleSessionDidBecomeActive(_ notification: Notification) {
        activityGate.sessionDidBecomeActive(screenIsAwake: Self.mainDisplayIsAwake)
        reconcileInteractiveTracking()
    }

    private func configureOutsideClickHandling() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.noteInteractiveActivity()
                self.closePopover()
                if self.quickAddWindow?.isVisible == true {
                    self.dismissQuickAddWindow()
                }
            }
        }
    }

    private func noteInteractiveActivity() {
        guard didFinishLaunching else { return }
        let screenIsAwake = Self.mainDisplayIsAwake
        if Self.currentSessionIsActive {
            activityGate.sessionDidBecomeActive(screenIsAwake: screenIsAwake)
        } else {
            activityGate.sessionDidResign()
        }
        if screenIsAwake {
            activityGate.systemDidWake()
        }
        reconcileInteractiveTracking()
    }

    private func reconcileInteractiveTracking() {
        guard didFinishLaunching else { return }
        if activityGate.isInteractive {
            if !trackingIsInteractive {
                trackingIsInteractive = true
                isAwaitingInitialMeetingEvaluation = true
                meetingMonitor.start()
            }
            store.resumeInteractiveTracking()
        } else {
            store.suspendTracking()
            isAwaitingInitialMeetingEvaluation = false
            deferredTaskFocusBannerID = nil
            if trackingIsInteractive {
                trackingIsInteractive = false
                meetingMonitor.suspend()
            }
        }
    }

    private func configureTrackingLifecycle() {
        store.onSuspensionDetected = { [weak self] in
            guard let self else { return }
            self.trackingIsInteractive = false
            self.meetingMonitor.suspend()
            self.activityGate = InteractiveActivityGate(
                powerAwake: true,
                screenAwake: Self.mainDisplayIsAwake,
                sessionActive: Self.currentSessionIsActive
            )
            self.reconcileInteractiveTracking()
        }
    }

    private static var mainDisplayIsAwake: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    private static var currentSessionIsActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        guard
            let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
            let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool
        else {
            return false
        }
        // This private key is present while locked and commonly absent while
        // unlocked. The public console/login facts above remain fail-closed.
        let screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && loginDone && !screenLocked
    }

    private func configureMeetingMonitor() {
        meetingMonitor.onMeetingStateChange = { [weak self] isActive in
            self?.handleMeetingStateChange(isActive)
        }
        meetingMonitor.onInitialEvaluationComplete = { [weak self] in
            self?.handleInitialMeetingEvaluationComplete()
        }
    }

    private func handleInitialMeetingEvaluationComplete() {
        isAwaitingInitialMeetingEvaluation = false
        guard !store.isInMeeting else {
            deferredTaskFocusBannerID = nil
            dismissFocusBanner()
            return
        }
        guard let taskID = deferredTaskFocusBannerID else { return }
        deferredTaskFocusBannerID = nil
        guard store.focusedTask?.id == taskID else { return }
        showFocusStartedBanner(.task(taskID))
    }

    private func handleMeetingStateChange(_ isActive: Bool) {
        guard isActive else {
            store.setMeetingActive(false)
            return
        }

        if store.isFocusTimeActive,
           store.focusTimeSchedule.confirmsMeetings,
           !confirmFocusTimeInterruption(
               title: "Pause focus for this meeting?",
               message: "Loop detected a meeting. Entering meeting mode will pause productive task focus until the meeting ends.",
               continueTitle: "Enter Meeting"
           ) {
            meetingMonitor.suppressCurrentMeetingUntilInactive()
            return
        }

        deferredTaskFocusBannerID = nil
        dismissFocusBanner()
        store.setMeetingActive(true)
    }

    private func configureStatusTitleUpdates() {
        store.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemTitle()
                    self?.evaluateTimerExpirationBanner()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func handleFocusModeDidEnd(_ notification: Notification) {
        showNextFocusBanner(after: 0.15)
    }

    @objc private func handleFocusDidStart(_ notification: Notification) {
        guard let start = notification.object as? FocusStart else { return }
        showFocusStartedBanner(start)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTaskManagerWindow()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
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
        menu.addItem(taskMenuItem(title: "Open Task Manager", action: #selector(showTaskManagerFromStatusMenu), imageName: "macwindow"))
        menu.addItem(.separator())

        addFocusedTaskItems(to: menu)

        menu.addItem(taskMenuItem(title: "Settings", action: #selector(showSettingsFromStatusMenu), imageName: "gearshape"))
        menu.addItem(taskMenuItem(title: "Stats", action: #selector(showStatsFromStatusMenu), imageName: "chart.bar"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(appDisplayName)", action: #selector(quitFromStatusMenu), keyEquivalent: "q"))

        menu.popUp(positioning: appNameItem, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func addFocusedTaskItems(to menu: NSMenu) {
        guard let task = store.focusedTask else {
            let noTaskItem = NSMenuItem(title: "No current task", action: nil, keyEquivalent: "")
            noTaskItem.isEnabled = false
            menu.addItem(noTaskItem)
            menu.addItem(.separator())
            return
        }

        let taskTitleItem = NSMenuItem(title: truncatedTrayTaskTitle(task.title), action: nil, keyEquivalent: "")
        taskTitleItem.isEnabled = false
        menu.addItem(taskTitleItem)

        menu.addItem(taskMenuItem(title: "Done", action: #selector(markCurrentTaskDoneFromStatusMenu), imageName: "checkmark.circle"))

        let extendItem = taskMenuItem(title: "Extend 5 minutes", action: #selector(extendCurrentTaskFiveMinutesFromStatusMenu), imageName: "timer")
        extendItem.isEnabled = task.iterationTimerMinutes != nil && !task.doneThisLoop && !task.finished && !task.isBacklog
        menu.addItem(extendItem)

        menu.addItem(taskMenuItem(title: "Snooze 30 minutes", action: #selector(snoozeCurrentTaskThirtyMinutesFromStatusMenu), imageName: "clock"))
        menu.addItem(taskMenuItem(title: "Schedule for Next Day", action: #selector(scheduleCurrentTaskForNextWorkingDayFromStatusMenu), imageName: "calendar.badge.clock"))
        menu.addItem(taskMenuItem(title: "Finish", action: #selector(finishCurrentTaskFromStatusMenu), imageName: "checkmark.seal"))
        menu.addItem(.separator())
    }

    private func taskMenuItem(title: String, action: Selector, imageName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = menuImage(imageName)
        return item
    }

    private func menuImage(_ systemName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    @objc private func endRoutineFromStatusMenu(_ sender: Any?) {
        store.endRoutineBlock()
    }

    @objc private func markCurrentTaskDoneFromStatusMenu(_ sender: Any?) {
        completeCurrentFocus()
    }

    private func performTrayPrimaryAction() {
        if store.isOnBreak {
            store.endBreak()
            return
        }

        if store.isInRoutine {
            requestBreak()
            return
        }

        requestBreak()
    }

    private func requestBreak() {
        closePopover()
        if store.isFocusTimeActive, !store.focusTimeSchedule.allowsBreaks {
            showFocusTimeRestriction(
                title: "Breaks are disabled during focus time",
                message: "End focus for today or enable breaks in Focus Time settings before starting one."
            )
            return
        }
        if store.isFocusTimeActive,
           !confirmFocusTimeInterruption(
               title: "Go on a break?",
               message: "Focus time is active until \(focusTimeEndText). Starting a break will pause productive task focus.",
               continueTitle: "Start Break"
           ) {
            return
        }
        store.startBreak()
    }

    private func confirmFocusTimeInterruption(
        title: String,
        message: String,
        continueTitle: String
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: continueTitle)
        alert.addButton(withTitle: "Keep Focusing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showFocusTimeRestriction(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Keep Focusing")
        alert.runModal()
    }

    private var focusTimeEndText: String {
        let endTime = store.focusTimeSchedule.endTime
        let date = Calendar.current.date(
            bySettingHour: endTime.hour,
            minute: endTime.minute,
            second: 0,
            of: Date()
        ) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func completeCurrentFocus() {
        if store.isInRoutine {
            store.endRoutineBlock()
            return
        }

        if store.isOnBreak {
            store.endBreak()
            return
        }

        if store.markFocusedTaskDone(openNextFocusedApp: true) {
            showFocusBanner()
        }
    }

    @objc private func extendCurrentTaskTwoMinutesFromStatusMenu(_ sender: Any?) {
        extendCurrentTask(by: 2)
    }

    @objc private func extendCurrentTaskFiveMinutesFromStatusMenu(_ sender: Any?) {
        extendCurrentTask(by: 5)
    }

    @objc private func scheduleCurrentTaskForNextWorkingDayFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        store.scheduleForNextWorkingDay(task)
    }

    @objc private func showSettingsFromStatusMenu(_ sender: Any?) {
        showSettingsWindow(initialSection: .general)
    }

    @objc private func showStatsFromStatusMenu(_ sender: Any?) {
        showSettingsWindow(initialSection: .stats)
    }

    @objc private func showTaskManagerFromStatusMenu(_ sender: Any?) {
        showTaskManagerWindow()
    }

    @objc private func snoozeCurrentTaskThirtyMinutesFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        store.snooze(task, minutes: 30)
    }

    @objc private func snoozeCurrentTaskFromStatusMenu(_ sender: NSMenuItem) {
        guard
            let minutes = sender.representedObject as? Int,
            let task = store.focusedTask
        else {
            return
        }
        store.snooze(task, minutes: minutes)
    }

    @objc private func unsnoozeCurrentTaskFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        store.unsnooze(task)
    }

    @objc private func editCurrentTaskFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        showTaskEditor(task)
    }

    private func showTaskEditor(_ task: LoopTask) {
        showTaskManagerWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .loopShouldEditTask, object: task.id)
        }
    }

    private func showRoutineEditor(_ routine: RoutineBlock) {
        showTaskManagerWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .loopShouldEditRoutine, object: routine.id)
        }
    }

    @objc private func toggleCurrentTaskPriorityFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        store.togglePriority(task)
    }

    @objc private func moveCurrentTaskToBacklogFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        store.moveToBacklog(task)
    }

    @objc private func finishCurrentTaskFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        store.finish(task)
    }

    @objc private func deleteCurrentTaskFromStatusMenu(_ sender: Any?) {
        guard let task = store.focusedTask else { return }
        store.delete(task)
    }

    private func extendCurrentTask(by minutes: Int) {
        guard let task = store.focusedTask else { return }
        store.extendIterationTimer(for: task, by: minutes)
    }

    @objc private func quitFromStatusMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Loop"
    }

    private func chooseApplication() -> LinkedApp? {
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
        let title = store.meetingTimerText
            ?? store.breakTimerText
            ?? store.routineTimerText
            ?? menuBarTitle(taskTitle: store.focusedTaskTitle, timerText: store.focusedTaskTimerText)
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        button.setAccessibilityLabel(title.isEmpty ? "Loop" : "Loop, \(title)")
        button.toolTip = store.meetingTimerText
            ?? store.breakTimerText
            ?? store.routineTimerText
            ?? menuBarTooltip(taskTitle: store.focusedTaskTitle, timerText: store.focusedTaskTimerText)
    }

    private func truncatedMenuBarTitle(_ title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTitle.isEmpty else { return "" }
        guard trimmedTitle.count > 34 else { return trimmedTitle }
        return "\(trimmedTitle.prefix(31))..."
    }

    private func truncatedTrayTaskTitle(_ title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTitle.isEmpty else { return "" }
        guard trimmedTitle.count > 24 else { return trimmedTitle }
        return "\(trimmedTitle.prefix(21))..."
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
        let timerSuffix = timerText.hasPrefix("-") ? "over" : "left"
        return "\(title) · \(timerText) \(timerSuffix)"
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        store.refreshCurrentDate()
        updatePopoverSize(for: button)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                let popoverWindow = self.popover.contentViewController?.view.window
            else { return }
            popoverWindow.collectionBehavior.formUnion([
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .transient
            ])
            popoverWindow.level = .statusBar
            popoverWindow.orderFrontRegardless()
        }
    }

    private func updatePopoverSize(for button: NSStatusBarButton) {
        let openTaskCount = store.currentLoopTasks.filter { !$0.doneThisLoop && !$0.finished }.count
        let openItemCount = openTaskCount + store.openRoutineBlocks.count
        // The tray header has two rows (navigation plus metrics), so reserve
        // enough fixed space before sizing the scrollable iteration queue.
        let desiredHeight = CGFloat(310 + (max(openItemCount, 1) * 35))
        let availableHeight = (button.window?.screen?.visibleFrame.height ?? 800) - 96
        popover.contentSize = NSSize(width: 360, height: min(desiredHeight, availableHeight))
    }

    private func showTaskManagerWindow() {
        closePopover()
        store.refreshCurrentDate()

        let window: NSWindow
        if let taskManagerWindow {
            window = taskManagerWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Loop"
            window.contentMinSize = NSSize(width: 440, height: 560)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.contentViewController = NSHostingController(rootView: LoopPanelView(
                onChooseApplication: { [weak self] in
                    self?.chooseApplication()
                },
                onShowMorningPlan: { [weak self] in
                    self?.showMorningPlanWindow()
                }
            )
            .environmentObject(store))

            let frameAutosaveName = "Loop.TaskManagerWindow"
            if !window.setFrameUsingName(frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(frameAutosaveName)
            taskManagerWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func showMorningPlanWindow() {
        closePopover()
        store.refreshCurrentDate()
        store.prepareMorningRoutine()

        if let morningPlanWindow, morningPlanWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            morningPlanWindow.deminiaturize(nil)
            morningPlanWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window: NSWindow
        if let morningPlanWindow {
            window = morningPlanWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Morning Plan"
            window.contentMinSize = NSSize(width: 520, height: 560)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed

            let frameAutosaveName = "Loop.MorningPlanWindow"
            if !window.setFrameUsingName(frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(frameAutosaveName)
            morningPlanWindow = window
        }

        window.contentViewController = NSHostingController(rootView: MorningOnboardingView(
            onChooseApplication: { [weak self] in
                self?.chooseApplication()
            },
            onComplete: { [weak self] in
                self?.morningPlanWindow?.close()
            }
        )
        .environmentObject(store))
        window.standardWindowButton(.closeButton)?.isEnabled = !store.isMorningRoutineRequired

        NSApp.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func showQuickAddWindow() {
        quickAddShouldReturnToBackground = !hasVisibleApplicationWindow

        let panelSize = NSSize(width: 380, height: 62)
        let panel = quickAddWindow ?? QuickAddPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setContentSize(panelSize)
        panel.contentView = NSHostingView(rootView: QuickAddTaskView(
            store: store,
            initialTitle: quickAddDraft,
            onDraftChange: { [weak self] draft in
                self?.quickAddDraft = draft
            },
            onDismiss: { [weak self] in
                self?.dismissQuickAddWindow()
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

    private var hasVisibleApplicationWindow: Bool {
        taskManagerWindow?.isVisible == true
            || morningPlanWindow?.isVisible == true
            || settingsWindow?.isVisible == true
    }

    private func dismissQuickAddWindow() {
        quickAddWindow?.close()
        let shouldReturnToBackground = quickAddShouldReturnToBackground
        quickAddShouldReturnToBackground = false
        guard shouldReturnToBackground, !hasVisibleApplicationWindow else { return }
        NSApp.hide(nil)
    }

    private func showSettingsWindow(initialSection: SettingsSection) {
        closePopover()

        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        window.title = initialSection == .stats ? "Loop Stats" : "Loop Settings"
        window.contentView = NSHostingView(rootView: SettingsPanelView(
            initialSection: initialSection,
            onChooseApplication: { [weak self] in
                self?.chooseApplication()
            },
            onClose: { [weak self] in
                self?.settingsWindow?.close()
            }
        )
        .environmentObject(store))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showFocusBanner() {
        let bannerState = FocusBannerState(task: store.focusedTask, routine: store.activeRoutineBlock)
        showBanner(state: bannerState) { [weak self] in
            guard let self else { return }
            if let focusedTask = self.store.focusedTask {
                self.store.openLinkedApp(for: focusedTask)
            } else if let activeRoutineBlock = self.store.activeRoutineBlock {
                self.store.openLinkedApp(for: activeRoutineBlock)
            }
            self.dismissFocusBanner()
        }
    }

    private func showFocusStartedBanner(_ start: FocusStart) {
        switch start {
        case .break:
            showBanner(
                state: FocusBannerState(
                    eyebrow: "Pause",
                    title: "Break started",
                    detail: store.breakTimerText ?? "Take a moment to reset",
                    systemImage: "cup.and.saucer.fill",
                    kind: .breakTime
                ),
                onClick: {}
            )
        case .routine(let routineID):
            let routine = store.activeRoutineBlock ?? store.routineBlocks.first { $0.id == routineID }
            showBanner(state: FocusBannerState(task: nil, routine: routine)) { [weak self] in
                guard let self else { return }
                if let routine {
                    self.store.openLinkedApp(for: routine)
                }
                self.dismissFocusBanner()
            }
        case .task(let taskID):
            if isAwaitingInitialMeetingEvaluation {
                deferredTaskFocusBannerID = taskID
                return
            }
            guard let task = store.tasks.first(where: { $0.id == taskID }) else { return }
            showBanner(state: FocusBannerState(task: task)) { [weak self] in
                guard let self else { return }
                self.store.openLinkedApp(for: task)
                self.dismissFocusBanner()
            }
        }
    }

    private func showNextFocusBanner(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.store.focusedTask != nil || self.store.activeRoutineBlock != nil else { return }
            self.showFocusBanner()
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
                eyebrow: "Timer",
                title: "Time is up",
                detail: task.title,
                systemImage: "timer",
                kind: .timerExpired
            ),
            onClick: {}
        )
    }

    private func showBanner(state: FocusBannerState, onClick: @escaping () -> Void) {
        let bannerView = FocusBannerView(state: state, onClick: onClick)

        let bannerSize = NSSize(width: 420, height: 92)
        let isNewPanel = focusBannerWindow == nil
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = !state.isClickable
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let finalFrame = focusBannerFrame(size: bannerSize)
        if isNewPanel {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.alphaValue = 0
            panel.setFrame(finalFrame.offsetBy(dx: 0, dy: reduceMotion ? 0 : 8), display: true)
        } else {
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: true)
        }

        focusBannerWindow = panel
        panel.orderFrontRegardless()

        if isNewPanel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.24
                panel.animator().alphaValue = 1
                panel.animator().setFrame(finalFrame, display: true)
            }
        }

        focusBannerDismissWorkItem?.cancel()
        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.dismissFocusBanner()
        }
        focusBannerDismissWorkItem = dismissWorkItem
        let displayDuration: TimeInterval = state.isClickable ? 4.8 : 4.2
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: dismissWorkItem)
    }

    private func focusBannerFrame(size: NSSize) -> NSRect {
        let visibleFrame = statusItem?.button?.window?.screen?.visibleFrame
            ?? NSApp.keyWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? .zero
        let x = visibleFrame.midX - (size.width / 2)
        let twoThirdsFromBottomCenterY = visibleFrame.minY + (visibleFrame.height * 2 / 3)
        let idealY = twoThirdsFromBottomCenterY - (size.height / 2)
        let y = min(
            max(idealY, visibleFrame.minY + 24),
            visibleFrame.maxY - size.height - 24
        )
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func dismissFocusBanner() {
        focusBannerDismissWorkItem?.cancel()
        focusBannerDismissWorkItem = nil
        guard let panel = focusBannerWindow else { return }
        focusBannerWindow = nil

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.close()
            return
        }

        let finalFrame = panel.frame.offsetBy(dx: 0, dy: 6)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
            panel.animator().setFrame(finalFrame, display: true)
        } completionHandler: {
            Task { @MainActor in
                panel.close()
            }
        }
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
                placeholder: "Add task",
                text: $title,
                onReturn: { currentTitle in
                    submit(currentTitle, addToIteration: true)
                },
                onCommandReturn: { currentTitle in
                    submit(currentTitle, addToIteration: false)
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
    override var canBecomeMain: Bool { false }
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

private enum FocusBannerKind {
    case focus
    case routine
    case breakTime
    case timerExpired
    case complete

    var tint: Color {
        switch self {
        case .focus:
            return Color(nsColor: .systemBlue)
        case .routine:
            return Color(nsColor: .systemIndigo)
        case .breakTime:
            return Color(nsColor: .systemMint)
        case .timerExpired:
            return Color(nsColor: .systemOrange)
        case .complete:
            return Color(nsColor: .systemGreen)
        }
    }

    var secondaryTint: Color {
        switch self {
        case .focus:
            return Color(nsColor: .systemCyan)
        case .routine:
            return Color(nsColor: .systemPurple)
        case .breakTime:
            return Color(nsColor: .systemTeal)
        case .timerExpired:
            return Color(nsColor: .systemYellow)
        case .complete:
            return Color(nsColor: .systemMint)
        }
    }
}

private struct FocusBannerState {
    let eyebrow: String
    let title: String
    let detail: String?
    let systemImage: String
    let kind: FocusBannerKind
    let isClickable: Bool

    init(
        eyebrow: String,
        title: String,
        detail: String? = nil,
        systemImage: String,
        kind: FocusBannerKind,
        isClickable: Bool = false
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.kind = kind
        self.isClickable = isClickable
    }

    init(task: LoopTask?, routine: RoutineBlock? = nil) {
        if let task {
            eyebrow = "Focus"
            title = task.title
            detail = Self.openDetail(for: task.linkedApp?.name)
            systemImage = "scope"
            kind = .focus
            isClickable = task.linkedApp != nil
        } else if let routine {
            eyebrow = "Routine"
            title = routine.title
            detail = Self.openDetail(for: routine.linkedApp?.name)
            systemImage = "clock.badge.checkmark"
            kind = .routine
            isClickable = routine.linkedApp != nil
        } else {
            eyebrow = "Loop"
            title = "Iteration complete"
            detail = "No task is waiting"
            systemImage = "checkmark.circle.fill"
            kind = .complete
            isClickable = false
        }
    }

    var accessibilityLabel: String {
        [eyebrow, title, detail]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func openDetail(for appName: String?) -> String? {
        guard let appName else { return nil }
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : "Open \(trimmedName)"
    }
}

private struct FocusBannerView: View {
    let state: FocusBannerState
    let onClick: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if state.isClickable {
            Button(action: onClick) {
                bannerSurface
            }
            .buttonStyle(FocusBannerButtonStyle())
            .onHover { hovering in
                isHovered = hovering
            }
            .accessibilityLabel(Text(state.accessibilityLabel))
            .accessibilityHint(Text("Opens the linked app"))
        } else {
            bannerSurface
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(state.accessibilityLabel))
        }
    }

    private var bannerSurface: some View {
        ZStack {
            liquidAtmosphere

            HStack(spacing: 13) {
                iconLens

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.eyebrow.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(state.kind.tint)

                    Text(state.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)

                    if let detail = state.detail {
                        Text(detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if state.isClickable {
                    actionLens
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 92)
        .modifier(
            FocusBannerSurfaceModifier(
                tint: state.kind.tint,
                isInteractive: state.isClickable,
                reduceTransparency: reduceTransparency
            )
        )
        .overlay {
            bannerShape
                .strokeBorder(borderGradient, lineWidth: colorSchemeContrast == .increased ? 1.25 : 0.8)
        }
        .contentShape(bannerShape)
        .scaleEffect(isHovered ? 1.008 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    private var iconLens: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            state.kind.tint.opacity(colorScheme == .dark ? 0.30 : 0.20),
                            state.kind.secondaryTint.opacity(colorScheme == .dark ? 0.16 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.58), state.kind.tint.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )

            Image(systemName: state.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.kind.tint)
        }
        .frame(width: 46, height: 46)
        .shadow(color: state.kind.tint.opacity(colorScheme == .dark ? 0.20 : 0.12), radius: 8, y: 3)
    }

    private var actionLens: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(isHovered ? 0.10 : 0.06))

            Circle()
                .strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.08), lineWidth: 0.8)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(isHovered ? state.kind.tint : Color.secondary)
        }
        .frame(width: 32, height: 32)
    }

    private var liquidAtmosphere: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .fill(state.kind.tint.opacity(reduceTransparency ? 0.05 : 0.10))
                    .frame(width: geometry.size.width * 0.52)
                    .blur(radius: 28)
                    .offset(x: -geometry.size.width * 0.35, y: -geometry.size.height * 0.24)

                Circle()
                    .fill(state.kind.secondaryTint.opacity(reduceTransparency ? 0.035 : 0.07))
                    .frame(width: geometry.size.width * 0.42)
                    .blur(radius: 32)
                    .offset(x: geometry.size.width * 0.38, y: geometry.size.height * 0.32)

                LinearGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.08 : 0.20), .clear, .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(bannerShape)
        .allowsHitTesting(false)
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(colorScheme == .dark ? 0.30 : 0.72), location: 0),
                .init(color: .white.opacity(colorScheme == .dark ? 0.08 : 0.18), location: 0.46),
                .init(color: .primary.opacity(colorSchemeContrast == .increased ? 0.24 : 0.10), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var bannerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }
}

private struct FocusBannerSurfaceModifier: ViewModifier {
    let tint: Color
    let isInteractive: Bool
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: bannerShape)
                .background(tint.opacity(0.06), in: bannerShape)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(tint.opacity(0.10)).interactive(isInteractive),
                    in: bannerShape
                )
        } else {
            content
                .background(.regularMaterial, in: bannerShape)
        }
    }

    private var bannerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }
}

private struct FocusBannerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.987 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
