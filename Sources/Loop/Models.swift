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
    var priorityDeferredLoop: Int?
    var iterationTimerMinutes: Int?
    var iterationTimerStartedAt: Date?
    var iterationTimerStartedLoop: Int?
    var scheduledFor: Date?
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
        priorityDeferredLoop: Int? = nil,
        iterationTimerMinutes: Int? = nil,
        iterationTimerStartedAt: Date? = nil,
        iterationTimerStartedLoop: Int? = nil,
        scheduledFor: Date? = nil,
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
        self.priorityDeferredLoop = priorityDeferredLoop
        self.iterationTimerMinutes = iterationTimerMinutes
        self.iterationTimerStartedAt = iterationTimerStartedAt
        self.iterationTimerStartedLoop = iterationTimerStartedLoop
        self.scheduledFor = scheduledFor
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
        case priorityDeferredLoop
        case iterationTimerMinutes
        case iterationTimerStartedAt
        case iterationTimerStartedLoop
        case scheduledFor
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
        priorityDeferredLoop = try container.decodeIfPresent(Int.self, forKey: .priorityDeferredLoop)
        iterationTimerMinutes = try container.decodeIfPresent(Int.self, forKey: .iterationTimerMinutes)
        iterationTimerStartedAt = try container.decodeIfPresent(Date.self, forKey: .iterationTimerStartedAt)
        iterationTimerStartedLoop = try container.decodeIfPresent(Int.self, forKey: .iterationTimerStartedLoop)
        scheduledFor = try container.decodeIfPresent(Date.self, forKey: .scheduledFor)
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
        try container.encodeIfPresent(priorityDeferredLoop, forKey: .priorityDeferredLoop)
        try container.encodeIfPresent(iterationTimerMinutes, forKey: .iterationTimerMinutes)
        try container.encodeIfPresent(iterationTimerStartedAt, forKey: .iterationTimerStartedAt)
        try container.encodeIfPresent(iterationTimerStartedLoop, forKey: .iterationTimerStartedLoop)
        try container.encodeIfPresent(scheduledFor, forKey: .scheduledFor)
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

struct BreakSession: Identifiable, Codable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

struct MeetingSession: Identifiable, Codable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

struct RoutineBlock: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var linkedApp: LinkedApp?
    var cadence: LoopCadence
    var durationMinutes: Int
    var countsAsProductive: Bool
    var isEnabled: Bool
    var scheduleTimes: [DailyScheduleTime]
    var lastCompletedScheduledAt: Date?
    var lastCompletedLoop: Int?
    var sortOrder: Double
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        linkedApp: LinkedApp? = nil,
        cadence: LoopCadence = .everyTwoLoops,
        durationMinutes: Int = 5,
        countsAsProductive: Bool = true,
        isEnabled: Bool = true,
        scheduleTimes: [DailyScheduleTime] = [],
        lastCompletedScheduledAt: Date? = nil,
        lastCompletedLoop: Int? = nil,
        sortOrder: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.linkedApp = linkedApp
        self.cadence = cadence
        self.durationMinutes = durationMinutes
        self.countsAsProductive = countsAsProductive
        self.isEnabled = isEnabled
        self.scheduleTimes = scheduleTimes
        self.lastCompletedScheduledAt = lastCompletedScheduledAt
        self.lastCompletedLoop = lastCompletedLoop
        self.sortOrder = sortOrder ?? createdAt.timeIntervalSinceReferenceDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case linkedApp
        case cadence
        case durationMinutes
        case countsAsProductive
        case isEnabled
        case scheduleTimes
        case lastCompletedScheduledAt
        case lastCompletedLoop
        case sortOrder
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        linkedApp = try container.decodeIfPresent(LinkedApp.self, forKey: .linkedApp)
        cadence = try container.decodeIfPresent(LoopCadence.self, forKey: .cadence) ?? .everyTwoLoops
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 5
        countsAsProductive = try container.decodeIfPresent(Bool.self, forKey: .countsAsProductive) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        scheduleTimes = try container.decodeIfPresent([DailyScheduleTime].self, forKey: .scheduleTimes) ?? []
        lastCompletedScheduledAt = try container.decodeIfPresent(Date.self, forKey: .lastCompletedScheduledAt)
        lastCompletedLoop = try container.decodeIfPresent(Int.self, forKey: .lastCompletedLoop)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sortOrder = try container.decodeIfPresent(Double.self, forKey: .sortOrder) ?? createdAt.timeIntervalSinceReferenceDate
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(linkedApp, forKey: .linkedApp)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encode(countsAsProductive, forKey: .countsAsProductive)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(scheduleTimes, forKey: .scheduleTimes)
        try container.encodeIfPresent(lastCompletedScheduledAt, forKey: .lastCompletedScheduledAt)
        try container.encodeIfPresent(lastCompletedLoop, forKey: .lastCompletedLoop)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct DailyScheduleTime: Identifiable, Codable, Equatable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    var id: String {
        String(format: "%02d:%02d", hour, minute)
    }

    init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    static func < (left: DailyScheduleTime, right: DailyScheduleTime) -> Bool {
        if left.hour == right.hour {
            return left.minute < right.minute
        }
        return left.hour < right.hour
    }
}

struct RoutineSession: Identifiable, Codable, Equatable {
    var id: UUID
    var routineBlockID: UUID
    var title: String
    var countsAsProductive: Bool
    var startedAt: Date
    var endedAt: Date

    init(
        id: UUID = UUID(),
        routineBlockID: UUID,
        title: String,
        countsAsProductive: Bool,
        startedAt: Date,
        endedAt: Date = Date()
    ) {
        self.id = id
        self.routineBlockID = routineBlockID
        self.title = title
        self.countsAsProductive = countsAsProductive
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

struct ActiveSession: Identifiable, Codable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

struct TaskCompletionStat: Identifiable, Equatable {
    var id: UUID
    var title: String
    var loopsTaken: Int
    var finishedAt: Date
}

struct LoopCadence: Codable, Identifiable, Hashable {
    var rawValue: Int

    static let everyLoop = LoopCadence(rawValue: 1)
    static let everyTwoLoops = LoopCadence(rawValue: 2)
    static let everyThreeLoops = LoopCadence(rawValue: 3)
    static let everyFourLoops = LoopCadence(rawValue: 4)
    static let maxLoops = 52

    var id: Int { rawValue }

    init(rawValue: Int) {
        self.rawValue = min(max(rawValue, 1), Self.maxLoops)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        rawValue == 1 ? "Every loop" : "Every \(rawValue) loops"
    }

    var compactTitle: String {
        rawValue == 1 ? "Every loop" : "Every \(rawValue)"
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
    static let defaultBreakShortcut = KeyboardShortcutSetting(key: "R", modifiers: [.control, .option])

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
