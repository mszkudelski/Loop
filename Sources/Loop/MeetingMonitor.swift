import AppKit
import CoreGraphics
import Foundation

@MainActor
final class MeetingMonitor: @unchecked Sendable {
    var onMeetingStateChange: ((Bool) -> Void)?

    private var timer: Timer?
    private let evaluationQueue = DispatchQueue(label: "local.loop.meeting-monitor", qos: .utility)
    private var lastReportedState = false
    private var consecutiveDetectedState: Bool?
    private var consecutiveDetectionCount = 0
    private var isSuppressingCurrentMeeting = false
    private var isEvaluating = false
    private var evaluationGeneration = 0

    func start() {
        stop()
        evaluationGeneration += 1
        isEvaluating = false
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func suspend() {
        stop()
        evaluationGeneration += 1
        isEvaluating = false
        lastReportedState = false
        consecutiveDetectedState = nil
        consecutiveDetectionCount = 0
        isSuppressingCurrentMeeting = false
    }

    func suppressCurrentMeetingUntilInactive() {
        isSuppressingCurrentMeeting = true
        lastReportedState = false
        consecutiveDetectedState = nil
        consecutiveDetectionCount = 0
    }

    private func evaluate() {
        guard !isEvaluating else { return }
        isEvaluating = true
        let generation = evaluationGeneration

        evaluationQueue.async { [weak self] in
            let detectedState = Self.isZoomMeetingActive()
            DispatchQueue.main.async {
                guard let self, self.evaluationGeneration == generation else { return }
                self.handleDetectedState(detectedState)
            }
        }
    }

    private func handleDetectedState(_ detectedState: Bool) {
        isEvaluating = false
        if isSuppressingCurrentMeeting {
            if detectedState {
                return
            }
            isSuppressingCurrentMeeting = false
        }

        if consecutiveDetectedState == detectedState {
            consecutiveDetectionCount += 1
        } else {
            consecutiveDetectedState = detectedState
            consecutiveDetectionCount = 1
        }

        let requiredConfirmations = detectedState ? 1 : 2
        guard consecutiveDetectionCount >= requiredConfirmations else { return }
        guard detectedState != lastReportedState else { return }

        lastReportedState = detectedState
        onMeetingStateChange?(detectedState)
    }

    private nonisolated static func isZoomMeetingActive() -> Bool {
        guard isZoomRunning else { return false }
        return hasZoomMeetingWindow || isZoomConferenceHostRunning
    }

    private nonisolated static var isZoomRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""
            let localizedName = app.localizedName?.lowercased() ?? ""
            return bundleIdentifier == "us.zoom.xos"
                || bundleIdentifier.contains("zoom")
                || localizedName == "zoom.us"
                || localizedName == "zoom"
        }
    }

    private nonisolated static var isZoomConferenceHostRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""
            let localizedName = app.localizedName?.lowercased() ?? ""
            let executableName = app.executableURL?.lastPathComponent.lowercased() ?? ""
            return bundleIdentifier == "us.zoom.cpthost"
                || localizedName == "cpthost"
                || executableName == "cpthost"
        }
    }

    private nonisolated static var hasZoomMeetingWindow: Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            guard let ownerName = window[kCGWindowOwnerName as String] as? String else { return false }
            let normalizedOwnerName = ownerName.lowercased()
            guard normalizedOwnerName.contains("zoom") else { return false }

            let windowName = (window[kCGWindowName as String] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return isMeetingWindowTitle(windowName)
        }
    }

    private nonisolated static func isMeetingWindowTitle(_ title: String) -> Bool {
        let normalizedTitle = title.lowercased()
        guard !normalizedTitle.isEmpty else { return false }

        let meetingSignals = [
            "zoom meeting",
            "zoom webinar",
            "meeting",
            "webinar",
            "waiting room",
            "breakout rooms",
            "participants",
            "share screen"
        ]
        let nonMeetingSignals = [
            "zoom workplace",
            "settings",
            "preferences",
            "sign in",
            "contacts",
            "team chat",
            "calendar",
            "scheduler",
            "whiteboards"
        ]

        return meetingSignals.contains { normalizedTitle.contains($0) }
            && !nonMeetingSignals.contains { normalizedTitle.contains($0) }
    }
}
