import Foundation

struct LoopTask: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var linkedApp: LinkedApp?
    var cadence: LoopCadence
    var doneThisLoop: Bool
    var finished: Bool
    var isPriority: Bool
    var isBacklog: Bool
    var lastCompletedLoop: Int?
    var sortOrder: Double
    var createdLoop: Int?
    var finishedLoop: Int?
    var finishedAt: Date?
    var snoozedUntil: Date?
    var snoozeCount: Int
    var manualFocusCount: Int
    var focusedAt: Date?
    var lastQuickCompletionAt: Date?
    var dismissedSuggestions: [LoopTaskSuggestion]
    var iterationTimerMinutes: Int?
    var iterationTimerStartedAt: Date?
    var iterationTimerStartedLoop: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        linkedApp: LinkedApp? = nil,
        cadence: LoopCadence = .everyLoop,
        doneThisLoop: Bool = false,
        finished: Bool = false,
        isPriority: Bool = false,
        isBacklog: Bool = false,
        lastCompletedLoop: Int? = nil,
        sortOrder: Double? = nil,
        createdLoop: Int? = nil,
        finishedLoop: Int? = nil,
        finishedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        snoozeCount: Int = 0,
        manualFocusCount: Int = 0,
        focusedAt: Date? = nil,
        lastQuickCompletionAt: Date? = nil,
        dismissedSuggestions: [LoopTaskSuggestion] = [],
        iterationTimerMinutes: Int? = nil,
        iterationTimerStartedAt: Date? = nil,
        iterationTimerStartedLoop: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.linkedApp = linkedApp
        self.cadence = cadence
        self.doneThisLoop = doneThisLoop
        self.finished = finished
        self.isPriority = isPriority
        self.isBacklog = isBacklog
        self.lastCompletedLoop = lastCompletedLoop
        self.sortOrder = sortOrder ?? createdAt.timeIntervalSinceReferenceDate
        self.createdLoop = createdLoop
        self.finishedLoop = finishedLoop
        self.finishedAt = finishedAt
        self.snoozedUntil = snoozedUntil
        self.snoozeCount = snoozeCount
        self.manualFocusCount = manualFocusCount
        self.focusedAt = focusedAt
        self.lastQuickCompletionAt = lastQuickCompletionAt
        self.dismissedSuggestions = dismissedSuggestions
        self.iterationTimerMinutes = iterationTimerMinutes
        self.iterationTimerStartedAt = iterationTimerStartedAt
        self.iterationTimerStartedLoop = iterationTimerStartedLoop
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case linkedApp
        case cadence
        case repeatsEveryLoop
        case doneThisLoop
        case finished
        case isPriority
        case isBacklog
        case lastCompletedLoop
        case sortOrder
        case createdLoop
        case finishedLoop
        case finishedAt
        case snoozedUntil
        case snoozeCount
        case manualFocusCount
        case focusedAt
        case lastQuickCompletionAt
        case dismissedSuggestions
        case iterationTimerMinutes
        case iterationTimerStartedAt
        case iterationTimerStartedLoop
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        linkedApp = try container.decodeIfPresent(LinkedApp.self, forKey: .linkedApp)
        cadence = try container.decodeIfPresent(LoopCadence.self, forKey: .cadence) ?? .everyLoop
        doneThisLoop = try container.decodeIfPresent(Bool.self, forKey: .doneThisLoop) ?? false
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        isPriority = try container.decodeIfPresent(Bool.self, forKey: .isPriority) ?? false
        isBacklog = try container.decodeIfPresent(Bool.self, forKey: .isBacklog) ?? false
        lastCompletedLoop = try container.decodeIfPresent(Int.self, forKey: .lastCompletedLoop)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? createdAt.timeIntervalSinceReferenceDate
        createdLoop = try container.decodeIfPresent(Int.self, forKey: .createdLoop)
        finishedLoop = try container.decodeIfPresent(Int.self, forKey: .finishedLoop)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        snoozeCount = try container.decodeIfPresent(Int.self, forKey: .snoozeCount) ?? 0
        manualFocusCount = try container.decodeIfPresent(Int.self, forKey: .manualFocusCount) ?? 0
        focusedAt = try container.decodeIfPresent(Date.self, forKey: .focusedAt)
        lastQuickCompletionAt = try container.decodeIfPresent(Date.self, forKey: .lastQuickCompletionAt)
        dismissedSuggestions = try container.decodeIfPresent([LoopTaskSuggestion].self, forKey: .dismissedSuggestions) ?? []
        iterationTimerMinutes = try container.decodeIfPresent(Int.self, forKey: .iterationTimerMinutes)
        iterationTimerStartedAt = try container.decodeIfPresent(Date.self, forKey: .iterationTimerStartedAt)
        iterationTimerStartedLoop = try container.decodeIfPresent(Int.self, forKey: .iterationTimerStartedLoop)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(linkedApp, forKey: .linkedApp)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(doneThisLoop, forKey: .doneThisLoop)
        try container.encode(finished, forKey: .finished)
        try container.encode(isPriority, forKey: .isPriority)
        try container.encode(isBacklog, forKey: .isBacklog)
        try container.encodeIfPresent(lastCompletedLoop, forKey: .lastCompletedLoop)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encodeIfPresent(createdLoop, forKey: .createdLoop)
        try container.encodeIfPresent(finishedLoop, forKey: .finishedLoop)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try container.encode(snoozeCount, forKey: .snoozeCount)
        try container.encode(manualFocusCount, forKey: .manualFocusCount)
        try container.encodeIfPresent(focusedAt, forKey: .focusedAt)
        try container.encodeIfPresent(lastQuickCompletionAt, forKey: .lastQuickCompletionAt)
        try container.encode(dismissedSuggestions, forKey: .dismissedSuggestions)
        try container.encodeIfPresent(iterationTimerMinutes, forKey: .iterationTimerMinutes)
        try container.encodeIfPresent(iterationTimerStartedAt, forKey: .iterationTimerStartedAt)
        try container.encodeIfPresent(iterationTimerStartedLoop, forKey: .iterationTimerStartedLoop)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct LoopCompletion: Identifiable, Codable, Equatable {
    var id: UUID
    var loopNumber: Int
    var completedAt: Date

    init(id: UUID = UUID(), loopNumber: Int, completedAt: Date = Date()) {
        self.id = id
        self.loopNumber = loopNumber
        self.completedAt = completedAt
    }
}

struct TaskCompletionStat: Identifiable, Equatable {
    var id: UUID
    var title: String
    var loopsTaken: Int
    var finishedAt: Date
}

enum LoopCadence: Int, Codable, CaseIterable, Identifiable, Hashable {
    case everyLoop = 1
    case everyTwoLoops = 2
    case everyThreeLoops = 3
    case everyFourLoops = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .everyLoop: "Every loop"
        case .everyTwoLoops: "Every 2 loops"
        case .everyThreeLoops: "Every 3 loops"
        case .everyFourLoops: "Every 4 loops"
        }
    }

    var compactTitle: String {
        switch self {
        case .everyLoop: "Every loop"
        case .everyTwoLoops: "Every 2"
        case .everyThreeLoops: "Every 3"
        case .everyFourLoops: "Every 4"
        }
    }

}

struct LinkedApp: Codable, Equatable, Hashable {
    var name: String
    var bundleIdentifier: String?
    var path: String?
}

enum ShortcutModifier: String, Codable, CaseIterable, Identifiable, Hashable {
    case control
    case option
    case command
    case shift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .shift: "Shift"
        }
    }
}

struct KeyboardShortcutSetting: Codable, Equatable {
    var key: String
    var modifiers: Set<ShortcutModifier>

    static let defaultShortcut = KeyboardShortcutSetting(key: "L", modifiers: [.control, .option])
    static let defaultDoneShortcut = KeyboardShortcutSetting(key: "D", modifiers: [.control, .option])
    static let defaultQuickAddShortcut = KeyboardShortcutSetting(key: "B", modifiers: [.control, .option])

    var normalized: KeyboardShortcutSetting {
        let normalizedKey = key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return KeyboardShortcutSetting(
            key: String(normalizedKey.prefix(1)),
            modifiers: modifiers
        )
    }

    var isValid: Bool {
        !normalized.key.isEmpty && !modifiers.isEmpty
    }

    var displayText: String {
        let orderedModifiers = ShortcutModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.title)
        return (orderedModifiers + [normalized.key]).joined(separator: " + ")
    }
}
