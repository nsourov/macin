import Foundation

public enum ItemKind: String, Codable, Sendable {
    case file
    case directory
    case package
    case symlink
    case externalResource
}

public enum StorageCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case applications
    case developerArtifacts
    case userFiles
    case cachesSupport
    case containersVMs
    case localAIModels
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .applications: return "Applications"
        case .developerArtifacts: return "Developer artifacts"
        case .userFiles: return "User files"
        case .cachesSupport: return "Caches & app data"
        case .containersVMs: return "Containers & VMs"
        case .localAIModels: return "Local AI models"
        case .other: return "Other / unclassified"
        }
    }

    public var symbol: String {
        switch self {
        case .applications: return "app.badge"
        case .developerArtifacts: return "hammer"
        case .userFiles: return "doc"
        case .cachesSupport: return "tray.full"
        case .containersVMs: return "shippingbox"
        case .localAIModels: return "cpu"
        case .other: return "questionmark.folder"
        }
    }
}

public final class FileNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let path: String
    public let name: String
    public let kind: ItemKind
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var ownLogicalSize: Int64
    public var ownAllocatedSize: Int64
    public var itemCount: Int
    public let modified: Date?
    public var children: [FileNode]
    public weak var parent: FileNode?
    public var isPartial: Bool
    var pendingChildren = 0
    var isFinalized = false
    var rootIndex = 0

    public convenience init(url: URL, kind: ItemKind, modified: Date?, logicalSize: Int64 = 0, allocatedSize: Int64 = 0) {
        self.init(url: url, path: url.path, name: nil, kind: kind, modified: modified, logicalSize: logicalSize, allocatedSize: allocatedSize)
    }

    init(url: URL, path: String, name: String?, kind: ItemKind, modified: Date?, logicalSize: Int64 = 0, allocatedSize: Int64 = 0) {
        self.url = url
        self.path = path
        self.name = name ?? (url.lastPathComponent.isEmpty ? path : url.lastPathComponent)
        self.kind = kind
        self.modified = modified
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.ownLogicalSize = kind == .file ? logicalSize : 0
        self.ownAllocatedSize = kind == .file ? allocatedSize : 0
        self.itemCount = kind == .file ? 1 : 0
        self.children = []
        self.isPartial = false
    }

    public var isContainer: Bool { kind == .directory || kind == .package }

    public func child(named name: String) -> FileNode? {
        children.first { $0.name == name }
    }

    public func find(path target: String) -> FileNode? {
        if path == target { return self }
        guard target.hasPrefix(path.hasSuffix("/") ? path : path + "/") else { return nil }
        for child in children where child.isContainer {
            if let hit = child.find(path: target) { return hit }
        }
        return children.first { $0.path == target }
    }

    public func forEachNode(_ body: (FileNode) -> Bool) {
        guard body(self) else { return }
        for child in children { child.forEachNode(body) }
    }
}

public enum RootAccessState: String, Codable, Sendable {
    case scanned
    case partial
    case inaccessible
    case missing
    case ignored
    case cancelled
}

public struct RootCoverage: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public var state: RootAccessState
    public var note: String?

    public init(path: String, state: RootAccessState, note: String? = nil) {
        self.path = path
        self.state = state
        self.note = note
    }
}

public enum SkipReason: String, Codable, Sendable {
    case permissionDenied
    case protectedByDefault
    case ignoredByUser
    case otherVolume
    case disappeared
    case readError
}

public struct SkippedItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path + reason.rawValue }
    public let path: String
    public let reason: SkipReason
    public let detail: String?

    public init(path: String, reason: SkipReason, detail: String? = nil) {
        self.path = path
        self.reason = reason
        self.detail = detail
    }

    public var reasonText: String {
        switch reason {
        case .permissionDenied: return "Permission denied (may need Full Disk Access or folder access)"
        case .protectedByDefault: return "Skipped by default to avoid macOS privacy prompts"
        case .ignoredByUser: return "In your ignore list"
        case .otherVolume: return "On another volume (not followed)"
        case .disappeared: return "Disappeared during scan"
        case .readError: return "Could not be read"
        }
    }
}

public struct ScanCoverage: Codable, Sendable {
    public var roots: [RootCoverage]
    public var skipped: [SkippedItem]
    public var skippedCount: Int
    public var hardLinkDuplicatesSkipped: Int
    public var symlinksNotFollowed: Int

    public init(roots: [RootCoverage] = [], skipped: [SkippedItem] = [], skippedCount: Int = 0, hardLinkDuplicatesSkipped: Int = 0, symlinksNotFollowed: Int = 0) {
        self.roots = roots
        self.skipped = skipped
        self.skippedCount = skippedCount
        self.hardLinkDuplicatesSkipped = hardLinkDuplicatesSkipped
        self.symlinksNotFollowed = symlinksNotFollowed
    }

    public var isComplete: Bool {
        skippedCount == 0 && roots.allSatisfy { $0.state == .scanned }
    }

    public var summaryText: String {
        let scanned = roots.filter { $0.state == .scanned || $0.state == .partial }.count
        if isComplete { return "Complete for \(scanned) location(s)" }
        return "Partial: \(scanned) of \(roots.count) location(s), \(skippedCount) item(s) skipped"
    }
}

public enum ScanStatus: String, Codable, Sendable {
    case running
    case completed
    case cancelled
    case failed
    case partial
}

public struct VolumeInfo: Codable, Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let availableImportantBytes: Int64

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    public init(identifier: String, name: String, totalBytes: Int64, availableBytes: Int64, availableImportantBytes: Int64) {
        self.identifier = identifier
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableImportantBytes = availableImportantBytes
    }

    public static func current(for url: URL = URL(fileURLWithPath: "/")) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeUUIDStringKey, .volumeNameKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return VolumeInfo(
            identifier: values.volumeUUIDString ?? url.path,
            name: values.volumeName ?? "Macintosh HD",
            totalBytes: total,
            availableBytes: available,
            availableImportantBytes: important
        )
    }
}

public struct ScanResult: @unchecked Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let status: ScanStatus
    public let roots: [FileNode]
    public let coverage: ScanCoverage
    public let volume: VolumeInfo?
    public let categoryTotals: [StorageCategory: Int64]
    public let scannedItemCount: Int
    public let rootSetHash: String

    public init(id: UUID, startedAt: Date, finishedAt: Date, status: ScanStatus, roots: [FileNode], coverage: ScanCoverage, volume: VolumeInfo?, categoryTotals: [StorageCategory: Int64], scannedItemCount: Int, rootSetHash: String) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.roots = roots
        self.coverage = coverage
        self.volume = volume
        self.categoryTotals = categoryTotals
        self.scannedItemCount = scannedItemCount
        self.rootSetHash = rootSetHash
    }

    public var totalAllocated: Int64 { roots.reduce(0) { $0 + $1.allocatedSize } }
    public var totalLogical: Int64 { roots.reduce(0) { $0 + $1.logicalSize } }

    public func node(at path: String) -> FileNode? {
        for root in roots {
            if let hit = root.find(path: path) { return hit }
        }
        return nil
    }

    public func largestItems(limit: Int, filesOnly: Bool = false) -> [FileNode] {
        var all: [FileNode] = []
        for root in roots {
            root.forEachNode { node in
                if node !== root, !filesOnly || node.kind == .file { all.append(node) }
                return true
            }
        }
        return Array(all.sorted { $0.allocatedSize > $1.allocatedSize }.prefix(limit))
    }
}

public enum ByteFormatter {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func memory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    public static func signed(_ bytes: Int64) -> String {
        let base = string(abs(bytes))
        if bytes > 0 { return "+" + base }
        if bytes < 0 { return "−" + base }
        return base
    }
}

public enum PathTools {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }

    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let base = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(base)
    }

    public static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || isDescendant(path, of: ancestor)
    }

    public static func display(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        if isDescendant(path, of: h) { return "~" + path.dropFirst(h.count) }
        return path
    }

    public static func rootSetHash(_ paths: [String]) -> String {
        let joined = paths.sorted().joined(separator: "\n")
        var hash: UInt64 = 1469598103934665603
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}
