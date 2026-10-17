import Foundation
import os

public struct UninstallEntry: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let bytes: Int64
    public let isApp: Bool
    public let outcome: CleanupItemOutcome
    public let message: String
}

public struct UninstallResult: Sendable {
    public let app: InstalledApp
    public let entries: [UninstallEntry]
    public let availableBefore: Int64?
    public let availableAfter: Int64?

    public var removed: [UninstallEntry] { entries.filter { $0.outcome == .movedToTrash || $0.outcome == .deleted } }
    public var problems: [UninstallEntry] { entries.filter { $0.outcome == .failed || $0.outcome == .skipped } }
    public var removedBytes: Int64 { removed.reduce(0) { $0 + $1.bytes } }
    public var appRemoved: Bool { removed.contains { $0.isApp } }
    public var measuredChange: Int64? {
        guard let availableBefore, let availableAfter else { return nil }
        return availableAfter - availableBefore
    }
}

public struct AppUninstaller: Sendable {
    private static let logger = Logger(subsystem: "com.macfootprint.app", category: "uninstall")

    public let home: URL
    public let policy: SafetyPolicy
    public let trashMover: any TrashMover
    public let mode: RemovalMode
    public let isRunning: @Sendable (InstalledApp) -> Bool

    public init(home: URL = PathTools.home, trashMover: any TrashMover = SystemTrashMover(), mode: RemovalMode = .trash, isRunning: @escaping @Sendable (InstalledApp) -> Bool = { _ in false }) {
        self.home = home.standardizedFileURL
        self.policy = SafetyPolicy(home: home)
        self.trashMover = trashMover
        self.mode = mode
        self.isRunning = isRunning
    }

    public var appRoots: [String] {
        ["/Applications", home.appendingPathComponent("Applications").path]
    }

    public func blockReason(for app: InstalledApp, checkRunning: Bool = true) -> String? {
        let url = URL(fileURLWithPath: app.path).standardizedFileURL
        let path = url.path
        if app.isProtected || path.hasPrefix("/System/") { return "This app is part of macOS and can't be removed." }
        guard url.pathExtension == "app" else { return "This is not an app." }
        guard appRoots.contains(where: { PathTools.isDescendant(path, of: $0) }) else {
            return "Macin only removes apps from the Applications folders."
        }
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .volumeIsReadOnlyKey]) else {
            return "The app is no longer there."
        }
        if values.isSymbolicLink == true { return "This is a shortcut, not the app itself." }
        if values.isDirectory != true { return "This is not an app." }
        if values.volumeIsReadOnly == true { return "macOS protects this app, so it can't be removed." }
        let current = AppDiscovery.read(url, location: app.location)
        if current?.bundleID != app.bundleID { return "The app changed since it was checked. Refresh and try again." }
        if checkRunning && isRunning(app) { return "\(app.name) is open. Quit it first." }
        return nil
    }

    public func blockReason(for item: RelatedItem) -> String? {
        let url = URL(fileURLWithPath: item.path).standardizedFileURL
        guard PathTools.isDescendant(url.path, of: home.appendingPathComponent("Library").path) else {
            return "Outside your Library folder"
        }
        if case .invalid(let why) = policy.check(url) { return why }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "No longer exists" }
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return "Is a shortcut now" }
        return nil
    }

    public func uninstall(_ app: InstalledApp, appBytes: Int64, removeApp: Bool, items: [RelatedItem]) async -> UninstallResult {
        let before = CleanupExecutor.availableBytes(home)
        var entries: [UninstallEntry] = []

        if removeApp, let why = blockReason(for: app) {
            entries.append(UninstallEntry(path: app.path, title: app.name, bytes: appBytes, isApp: true, outcome: .skipped, message: why))
            for item in items {
                entries.append(UninstallEntry(path: item.path, title: item.category.rawValue, bytes: item.bytes, isApp: false, outcome: .skipped, message: "Kept because the app was not removed"))
            }
            return UninstallResult(app: app, entries: entries, availableBefore: before, availableAfter: before)
        }

        if removeApp {
            entries.append(remove(path: app.path, title: app.name, bytes: appBytes, isApp: true))
        }
        for item in items {
            if Task.isCancelled {
                entries.append(UninstallEntry(path: item.path, title: item.category.rawValue, bytes: item.bytes, isApp: false, outcome: .skipped, message: "Cancelled before this item"))
                continue
            }
            if let why = blockReason(for: item) {
                entries.append(UninstallEntry(path: item.path, title: item.category.rawValue, bytes: item.bytes, isApp: false, outcome: .skipped, message: why))
                continue
            }
            entries.append(remove(path: item.path, title: item.category.rawValue, bytes: item.bytes, isApp: false))
        }
        return UninstallResult(app: app, entries: entries, availableBefore: before, availableAfter: CleanupExecutor.availableBytes(home))
    }

    private func remove(path: String, title: String, bytes: Int64, isApp: Bool) -> UninstallEntry {
        let url = URL(fileURLWithPath: path)
        if mode == .permanent {
            do {
                try FileManager.default.removeItem(at: url)
                return UninstallEntry(path: path, title: title, bytes: bytes, isApp: isApp, outcome: .deleted, message: "Deleted permanently")
            } catch {
                Self.logger.error("Delete failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        do {
            _ = try trashMover.trash(url)
            return UninstallEntry(path: path, title: title, bytes: bytes, isApp: isApp, outcome: .movedToTrash, message: "Moved to Trash")
        } catch {
            Self.logger.error("Trash failed: \(error.localizedDescription, privacy: .private)")
            return UninstallEntry(path: path, title: title, bytes: bytes, isApp: isApp, outcome: .failed, message: "Could not remove it. Nothing was deleted. (\(error.localizedDescription))")
        }
    }
}
