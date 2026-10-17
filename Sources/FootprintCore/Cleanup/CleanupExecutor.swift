import Foundation
import os

public enum ValidationOutcome: Sendable, Equatable {
    case valid
    case invalid(String)
}

public enum CleanupItemOutcome: String, Codable, Sendable {
    case movedToTrash
    case deleted
    case failed
    case skipped
}

public enum RemovalMode: String, Sendable {
    case trash
    case permanent
}

public struct CleanupItemResult: Identifiable, Codable, Sendable {
    public var id: UUID { candidate.id }
    public let candidate: CleanupCandidate
    public let outcome: CleanupItemOutcome
    public let message: String
    public let trashURL: URL?
}

public struct CleanupRunResult: Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let goalBytes: Int64?
    public let items: [CleanupItemResult]
    public let availableBefore: Int64?
    public let availableAfter: Int64?

    public var moved: [CleanupItemResult] { items.filter { $0.outcome == .movedToTrash || $0.outcome == .deleted } }
    public var trashed: [CleanupItemResult] { items.filter { $0.outcome == .movedToTrash } }
    public var deleted: [CleanupItemResult] { items.filter { $0.outcome == .deleted } }
    public var failed: [CleanupItemResult] { items.filter { $0.outcome == .failed } }
    public var skipped: [CleanupItemResult] { items.filter { $0.outcome == .skipped } }
    public var movedEstimatedBytes: Int64 { moved.reduce(0) { $0 + $1.candidate.estimatedReclaimableBytes } }
    public var measuredChange: Int64? {
        guard let availableBefore, let availableAfter else { return nil }
        return availableAfter - availableBefore
    }
}

public struct SafetyPolicy: Sendable {
    public let home: String
    public let forbiddenPrefixes: [String]
    public let forbiddenExact: [String]

    public init(home: URL = PathTools.home) {
        self.home = home.standardizedFileURL.path
        forbiddenPrefixes = ["/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/etc", "/var", "/Applications", "/cores", "/opt", "/Volumes"]
        let h = self.home
        forbiddenExact = [
            h,
            "\(h)/Library", "\(h)/Library/Caches", "\(h)/Library/Developer", "\(h)/Library/Application Support",
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/Library/Developer/Xcode", "\(h)/Library/Developer/Xcode/DerivedData", "\(h)/.Trash"
        ]
    }

    public func check(_ url: URL) -> ValidationOutcome {
        let path = url.standardizedFileURL.path
        if path.contains("/../") || path.hasSuffix("/..") { return .invalid("Path is not canonical") }
        if forbiddenExact.contains(path) { return .invalid("This is a top-level folder Macin never removes") }
        if forbiddenPrefixes.contains(where: { PathTools.isSameOrDescendant(path, of: $0) }) && !PathTools.isDescendant(path, of: home) {
            return .invalid("System or shared location; outside what Macin may change")
        }
        guard PathTools.isDescendant(path, of: home) else {
            return .invalid("Outside your home folder")
        }
        if PathTools.isSameOrDescendant(path, of: "\(home)/.Trash") { return .invalid("Already in Trash") }
        return .valid
    }
}

public protocol TrashMover: Sendable {
    func trash(_ url: URL) throws -> URL?
}

public struct SystemTrashMover: TrashMover {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

public struct CleanupExecutor: Sendable {
    private static let logger = Logger(subsystem: "com.macfootprint.app", category: "cleanup")

    public let policy: SafetyPolicy
    public let trashMover: any TrashMover
    public let runningBundleIDs: @Sendable () -> Set<String>
    public let volumeURL: URL
    public let mode: RemovalMode

    public init(policy: SafetyPolicy = SafetyPolicy(), trashMover: any TrashMover = SystemTrashMover(), volumeURL: URL = PathTools.home, mode: RemovalMode = .trash, runningBundleIDs: @escaping @Sendable () -> Set<String> = { [] }) {
        self.policy = policy
        self.trashMover = trashMover
        self.volumeURL = volumeURL
        self.mode = mode
        self.runningBundleIDs = runningBundleIDs
    }

    public func revalidate(_ candidate: CleanupCandidate) -> ValidationOutcome {
        guard candidate.actionType == .moveToTrash else { return .invalid("No automatic action exists for this item") }
        guard candidate.eligibility.isSelectable else { return .invalid("Item is \(candidate.eligibility.title.lowercased())") }
        guard candidate.url.isFileURL else { return .invalid("Not a file on disk") }
        if case .invalid(let why) = policy.check(candidate.url) { return .invalid(why) }

        let fm = FileManager.default
        guard let current = ItemIdentity.read(candidate.url) else { return .invalid("Item no longer exists") }
        if current.isSymlink { return .invalid("Item is now a symbolic link") }
        guard let expected = candidate.identity else { return .invalid("No identity recorded at scan time") }
        if current.fileNumber != expected.fileNumber || current.deviceNumber != expected.deviceNumber {
            return .invalid("A different item now exists at this path")
        }
        if let then = expected.modified, let now = current.modified, abs(now.timeIntervalSince(then)) > 1 {
            return .invalid("Item changed since the scan. Scan again to refresh it")
        }

        let resolved = candidate.url.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved != candidate.url.standardizedFileURL.path, case .invalid(let why) = policy.check(URL(fileURLWithPath: resolved)) {
            return .invalid("Path resolves elsewhere: \(why)")
        }

        switch candidate.detectorID {
        case "node.node-modules":
            let project = candidate.url.deletingLastPathComponent()
            if !fm.fileExists(atPath: project.appendingPathComponent("package.json").path) {
                return .invalid("package.json is gone; ownership can no longer be confirmed")
            }
        case "xcode.derived-data":
            if runningBundleIDs().contains(XcodeDerivedDataDetector.xcodeBundleID) && candidate.eligibility == .eligible {
                return .invalid("Xcode started after the scan; quit Xcode or review again")
            }
        default:
            break
        }
        return .valid
    }

    public func execute(_ approved: [CleanupCandidate], goalBytes: Int64?, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> CleanupRunResult {
        let started = Date()
        let before = Self.availableBytes(volumeURL)
        let summary = CleanupPlanner.summarize(approved)
        var results: [CleanupItemResult] = summary.overlapping.map {
            CleanupItemResult(candidate: $0, outcome: .skipped, message: "Covered by another selected item", trashURL: nil)
        }

        for (index, candidate) in summary.items.enumerated() {
            progress?(index, summary.items.count)
            if Task.isCancelled {
                results.append(CleanupItemResult(candidate: candidate, outcome: .skipped, message: "Cleanup was cancelled before this item", trashURL: nil))
                continue
            }
            if case .invalid(let why) = revalidate(candidate) {
                results.append(CleanupItemResult(candidate: candidate, outcome: .skipped, message: why, trashURL: nil))
                continue
            }
            if mode == .permanent {
                do {
                    try FileManager.default.removeItem(at: candidate.url)
                    results.append(CleanupItemResult(candidate: candidate, outcome: .deleted, message: "Deleted permanently", trashURL: nil))
                } catch {
                    Self.logger.error("Delete failed: \(error.localizedDescription, privacy: .private)")
                    results.append(CleanupItemResult(candidate: candidate, outcome: .failed, message: "Could not delete this item. (\(error.localizedDescription))", trashURL: nil))
                }
                continue
            }
            do {
                let trashURL = try trashMover.trash(candidate.url)
                results.append(CleanupItemResult(candidate: candidate, outcome: .movedToTrash, message: "Moved to Trash", trashURL: trashURL))
            } catch {
                Self.logger.error("Trash failed: \(error.localizedDescription, privacy: .private)")
                results.append(CleanupItemResult(candidate: candidate, outcome: .failed, message: "Could not move to Trash. Nothing was deleted. (\(error.localizedDescription))", trashURL: nil))
            }
        }
        progress?(summary.items.count, summary.items.count)

        return CleanupRunResult(
            id: UUID(),
            startedAt: started,
            finishedAt: Date(),
            goalBytes: goalBytes,
            items: results,
            availableBefore: before,
            availableAfter: Self.availableBytes(volumeURL)
        )
    }

    public static func availableBytes(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}
