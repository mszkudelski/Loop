import AppKit
import Foundation

@MainActor
final class MeetingMonitor {
    var onMeetingStateChange: ((Bool) -> Void)?

    private let meetingBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.apple.FaceTime"
    ]

    private var timer: Timer?
    private var isMeetingActive = false
    private var isSuppressedUntilInactive = false

    func start() {
        stop()
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func suppressUntilInactive() {
        isSuppressedUntilInactive = true
    }

    private func evaluate() {
        let detectedMeeting = hasActiveMeetingApplication()

        if isSuppressedUntilInactive {
            if detectedMeeting {
                return
            }
            isSuppressedUntilInactive = false
        }

        guard detectedMeeting != isMeetingActive else { return }
        isMeetingActive = detectedMeeting
        onMeetingStateChange?(detectedMeeting)
    }

    private func hasActiveMeetingApplication() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            guard !application.isTerminated else { return false }
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return meetingBundleIdentifiers.contains(bundleIdentifier)
        }
    }
}
