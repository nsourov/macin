import Foundation

public enum AssistantModule: String, Codable, Sendable, CaseIterable {
    case storage, memory, performance, applications, battery, network, general

    public var title: String {
        switch self {
        case .storage: return "Storage"
        case .memory: return "Memory"
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .battery: return "Battery"
        case .network: return "Network"
        case .general: return "General"
        }
    }
}

public enum EvidenceLevel: String, Codable, Sendable {
    case ok, note, concern
}

public struct Evidence: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let module: AssistantModule
    public let title: String
    public let value: String
    public let level: EvidenceLevel

    public init(id: String, module: AssistantModule, title: String, value: String, level: EvidenceLevel = .note) {
        self.id = id
        self.module = module
        self.title = title
        self.value = value
        self.level = level
    }
}

public struct AssistantAction: Sendable, Equatable {
    public let id: String
    public let title: String
    public let module: AssistantModule
}

public enum ActionRegistry {
    public static let all: [AssistantAction] = [
        AssistantAction(id: "open.storage", title: "Open Storage", module: .storage),
        AssistantAction(id: "review.cleanup", title: "Review cleanup", module: .storage),
        AssistantAction(id: "open.memory", title: "Open Memory", module: .memory),
        AssistantAction(id: "open.performance", title: "Open Performance", module: .performance),
        AssistantAction(id: "open.applications", title: "Open Applications", module: .applications),
        AssistantAction(id: "open.battery", title: "Open Battery", module: .battery),
        AssistantAction(id: "open.network", title: "Open Network", module: .network),
        AssistantAction(id: "run.networkCheck", title: "Run a network check", module: .network)
    ]

    public static func action(_ id: String?) -> AssistantAction? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

public struct AssistantStep: Codable, Sendable, Equatable {
    public let text: String
    public let action: String?

    public init(text: String, action: String? = nil) {
        self.text = text
        self.action = action
    }
}

public struct AssistantAnswer: Codable, Sendable, Equatable {
    public var summary: String
    public var interpretation: String
    public var evidenceIDs: [String]
    public var steps: [AssistantStep]
    public var unknowns: [String]

    public init(summary: String, interpretation: String, evidenceIDs: [String], steps: [AssistantStep], unknowns: [String] = []) {
        self.summary = summary
        self.interpretation = interpretation
        self.evidenceIDs = evidenceIDs
        self.steps = steps
        self.unknowns = unknowns
    }
}
