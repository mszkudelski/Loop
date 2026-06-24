import Carbon
import Foundation

final class HotKeyManager: @unchecked Sendable {
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?
    var onRegistrationError: ((String) -> Void)?

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(_ shortcut: KeyboardShortcutSetting, id: UInt32, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        let shortcut = shortcut.normalized
        guard shortcut.isValid, let keyCode = KeyCodeMap.keyCode(for: shortcut.key) else {
            onRegistrationError?("Choose a shortcut with at least one modifier and a supported key.")
            return false
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x4C4F4F50, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            shortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            onRegistrationError?("macOS rejected \(shortcut.displayText). Try another combination.")
            return false
        }

        if let hotKeyRef {
            hotKeyRefs[id] = hotKeyRef
            actions[id] = action
        }
        return true
    }

    func unregister(id: UInt32) {
        if let hotKeyRef = hotKeyRefs[id] {
            UnregisterEventHotKey(hotKeyRef)
            hotKeyRefs[id] = nil
        }
        actions[id] = nil
    }

    func unregister() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, let action = manager.actions[hotKeyID.id] else {
                    return noErr
                }

                DispatchQueue.main.async {
                    action()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )

        if status != noErr {
            NSLog("Loop could not install global shortcut handler: \(status)")
        }
    }
}

private extension KeyboardShortcutSetting {
    var carbonModifierFlags: UInt32 {
        var flags = UInt32(0)

        if modifiers.contains(.command) {
            flags |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            flags |= UInt32(shiftKey)
        }

        return flags
    }
}

private enum KeyCodeMap {
    private static let map: [String: Int] = [
        "A": 0,
        "S": 1,
        "D": 2,
        "F": 3,
        "H": 4,
        "G": 5,
        "Z": 6,
        "X": 7,
        "C": 8,
        "V": 9,
        "B": 11,
        "Q": 12,
        "W": 13,
        "E": 14,
        "R": 15,
        "Y": 16,
        "T": 17,
        "1": 18,
        "2": 19,
        "3": 20,
        "4": 21,
        "6": 22,
        "5": 23,
        "=": 24,
        "9": 25,
        "7": 26,
        "-": 27,
        "8": 28,
        "0": 29,
        "]": 30,
        "O": 31,
        "U": 32,
        "[": 33,
        "I": 34,
        "P": 35,
        "L": 37,
        "J": 38,
        "'": 39,
        "K": 40,
        ";": 41,
        "\\": 42,
        ",": 43,
        "/": 44,
        "N": 45,
        "M": 46,
        ".": 47,
        "`": 50
    ]

    static func keyCode(for key: String) -> Int? {
        map[key.uppercased()]
    }
}
