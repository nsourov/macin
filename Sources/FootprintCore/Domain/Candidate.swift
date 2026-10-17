import Foundation

public enum CandidateClassification: String, Codable, Sendable {
    case buildOutput
    case cache
    case projectDependency
    case containerResource
    case localModel
    case deviceSupport
    case unknown

    public var title: String {
        switch self {
        case .buildOutput: return "Build output"
        case .cache: return "Cache"
        case .projectDependency: return "Project dependency"
        case .containerResource: return "Container resource"
        case .localModel: return "Local model"
        case .deviceSupport: return "Device support files"
        case .unknown: return "Unknown"
        }
    }
}

public enum Confidence: String, Codable, Sendable, Comparable, CaseIterable {
    case high
    case medium
    case low

    var rank: Int {
        switch self {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }

    public var title: String { rawValue.capitalized + " confidence" }
}

public enum Eligibility: String, Codable, Sendable {
    case eligible
    case needsUserReview
    case informationalOnly
    case blocked

    public var title: String {
        switch self {
        case .eligible: return "Eligible"
        case .needsUserReview: return "Needs your review"
        case .informationalOnly: return "Info only"
        case .blocked: return "Blocked"
        }
    }

    public var isSelectable: Bool { self == .eligible || self == .needsUserReview }
}

public enum RiskLevel: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high

    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }

    public var title: String { rawValue.capitalized + " risk" }
}

public enum CleanupActionType: String, Codable, Sendable {
    case moveToTrash
    case adapterHandoff
    case informationalOnly

    public var title: String {
        switch self {
        case .moveToTrash: return "Move to Trash"
        case .adapterHandoff: return "Review in the tool"
        case .informationalOnly: return "No action"
        }
    }
}

public enum Reversibility: String, Codable, Sendable {
    case expected
    case conditional
    case none

    public var title: String {
        switch self {
        case .expected: return "Reversible (restore from Trash)"
        case .conditional: return "Reversible in some cases"
        case .none: return "Not reversible"
        }
    }
}

public enum CandidateSource: String, Codable, Sendable, CaseIterable {
    case xcode
    case projectDependencies
    case caches
    case containers
    case localModels
    case other

    public var title: String {
        switch self {
        case .xcode: return "Xcode"
        case .projectDependencies: return "Project files you can rebuild"
        case .caches: return "Caches"
        case .containers: return "Containers"
        case .localModels: return "Local AI models"
        case .other: return "Developer tools"
        }
    }
}

public struct ItemIdentity: Codable, Sendable, Hashable {
    public let fileNumber: UInt64
    public let deviceNumber: Int64
    public let modified: Date?
    public let isSymlink: Bool

    public init(fileNumber: UInt64, deviceNumber: Int64, modified: Date?, isSymlink: Bool) {
        self.fileNumber = fileNumber
        self.deviceNumber = deviceNumber
        self.modified = modified
        self.isSymlink = isSymlink
    }

    public static func read(_ url: URL) -> ItemIdentity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let number = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let device = (attrs[.systemNumber] as? NSNumber)?.int64Value ?? 0
        let modified = attrs[.modificationDate] as? Date
        let type = attrs[.type] as? FileAttributeType
        return ItemIdentity(fileNumber: number, deviceNumber: device, modified: modified, isSymlink: type == .typeSymbolicLink)
    }
}

public struct CleanupCandidate: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let detectorID: String
    public let detectorVersion: Int
    public let url: URL
    public let title: String
    public let itemKind: ItemKind
    public let logicalSizeBytes: Int64
    public let allocatedSizeBytes: Int64
    public let classification: CandidateClassification
    public let source: CandidateSource
    public let confidence: Confidence
    public let confidenceReasons: [String]
    public let eligibility: Eligibility
    public let riskLevel: RiskLevel
    public let riskEvidence: [String]
    public let reason: String
    public let consequences: [String]
    public let actionType: CleanupActionType
    public let reversibility: Reversibility
    public let lastModified: Date?
    public let identity: ItemIdentity?
    public let handoffHint: String?

    public init(
        id: UUID = UUID(),
        detectorID: String,
        detectorVersion: Int,
        url: URL,
        title: String,
        itemKind: ItemKind,
        logicalSizeBytes: Int64,
        allocatedSizeBytes: Int64,
        classification: CandidateClassification,
        source: CandidateSource,
        confidence: Confidence,
        confidenceReasons: [String],
        eligibility: Eligibility,
        riskLevel: RiskLevel,
        riskEvidence: [String],
        reason: String,
        consequences: [String],
        actionType: CleanupActionType,
        reversibility: Reversibility,
        lastModified: Date?,
        identity: ItemIdentity?,
        handoffHint: String? = nil
    ) {
        self.id = id
        self.detectorID = detectorID
        self.detectorVersion = detectorVersion
        self.url = url
        self.title = title
        self.itemKind = itemKind
        self.logicalSizeBytes = logicalSizeBytes
        self.allocatedSizeBytes = allocatedSizeBytes
        self.classification = classification
        self.source = source
        self.confidence = confidence
        self.confidenceReasons = confidenceReasons
        self.eligibility = eligibility
        self.riskLevel = riskLevel
        self.riskEvidence = riskEvidence
        self.reason = reason
        self.consequences = consequences
        self.actionType = actionType
        self.reversibility = reversibility
        self.lastModified = lastModified
        self.identity = identity
        self.handoffHint = handoffHint
    }

    public var path: String { url.path }
    public var estimatedReclaimableBytes: Int64 { allocatedSizeBytes > 0 ? allocatedSizeBytes : logicalSizeBytes }
    public var isSelectable: Bool { eligibility.isSelectable && actionType == .moveToTrash }
    public var canBeAutoSuggested: Bool { eligibility == .eligible && actionType == .moveToTrash && confidence != .low }
}
