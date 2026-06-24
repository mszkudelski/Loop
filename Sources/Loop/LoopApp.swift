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
        button.action = #selector(togglePopover)
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
        store.onShortcutChange = { [weak self] shortcut in
            self?.registerPopoverHotKey(shortcut)
        }
        store.onDoneShortcutChange = { [weak self] shortcut in
            self?.registerDoneHotKey(shortcut)
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
        let title = truncatedMenuBarTitle(store.focusedTaskTitle)
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = store.focusedTaskTitle ?? "Open"
    }

    private func truncatedMenuBarTitle(_ title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTitle.isEmpty else { return "" }
        guard trimmedTitle.count > 34 else { return trimmedTitle }
        return "\(trimmedTitle.prefix(31))..."
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showFocusBanner() {
        let bannerState = FocusBannerState(task: store.focusedTask)
        let bannerView = FocusBannerView(state: bannerState) { [weak self] in
            guard let self else { return }
            if let focusedTask = self.store.focusedTask {
                self.store.openLinkedApp(for: focusedTask)
            }
            self.dismissFocusBanner()
        }

        let bannerSize = NSSize(width: 300, height: 58)
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

private struct FocusBannerState {
    let title: String
    let subtitle: String
    let systemImage: String
    let isClickable: Bool

    init(task: LoopTask?) {
        if let task {
            title = "Now"
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
        HStack(spacing: 10) {
            Image(systemName: state.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Text(state.subtitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(width: 300, height: 58)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            if state.isClickable {
                onClick()
            }
        }
    }
}
