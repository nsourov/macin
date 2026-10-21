import AppKit
import FootprintCore
import SwiftUI

@MainActor
final class ApplicationsModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var sizingRemaining = 0
    @Published private(set) var lastScan: Date?
    @Published private(set) var scannedRoots: [String] = []
    @Published private(set) var skippedRoots: [String] = []
    @Published private(set) var running: Set<String> = []

    private var related: [String: [RelatedItem]] = [:]
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunning() }
            })
        }
        refreshRunning()
    }

    var totalBytes: Int64 { apps.reduce(0) { $0 + (sizes[$1.path] ?? 0) } }
    var runningCount: Int { apps.filter { running.contains($0.path) }.count }
    var isMeasuring: Bool { sizingRemaining > 0 }

    func loadIfNeeded() {
        if lastScan == nil && !isLoading { reload() }
    }

    func reload() {
        task?.cancel()
        isLoading = true
        refreshRunning()
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { AppDiscovery.discover() }.value
            guard let self, !Task.isCancelled else { return }
            withAnimation(Motion.smooth) {
                self.apps = result.apps
                self.scannedRoots = result.scannedRoots
                self.skippedRoots = result.skippedRoots
                self.lastScan = Date()
                self.isLoading = false
            }
            self.related = [:]
            await self.measure(result.apps)
        }
    }

    private func measure(_ list: [InstalledApp]) async {
        sizingRemaining = list.count
        await withTaskGroup(of: (String, Int64).self) { group in
            var queue = list.makeIterator()
            func enqueue() {
                guard let app = queue.next() else { return }
                group.addTask(priority: .utility) { (app.path, DiskUsage.allocatedSize(of: URL(fileURLWithPath: app.path))) }
            }
            for _ in 0..<4 { enqueue() }
            while let (path, size) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                sizes[path] = size
                sizingRemaining -= 1
                enqueue()
            }
        }
        sizingRemaining = 0
    }

    func measureIfNeeded(_ app: InstalledApp) async {
        guard sizes[app.path] == nil else { return }
        let size = await Task.detached(priority: .userInitiated) { DiskUsage.allocatedSize(of: URL(fileURLWithPath: app.path)) }.value
        sizes[app.path] = size
    }

    func relatedItems(for app: InstalledApp) async -> [RelatedItem] {
        if let cached = related[app.path] { return cached }
        let items = await Task.detached(priority: .userInitiated) { RelatedDataScanner.scan(for: app) }.value
        related[app.path] = items
        return items
    }

    func app(forPath path: String) -> InstalledApp? {
        if let known = apps.first(where: { $0.path == path }) { return known }
        let location: AppLocation = path.hasPrefix("/System/") ? .system : (path.hasPrefix("/Applications/") ? .applications : .other)
        return AppDiscovery.read(URL(fileURLWithPath: path), location: location)
    }

    func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    func open(_ app: InstalledApp) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func runningApps(_ app: InstalledApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == app.path }
    }

    func quit(_ app: InstalledApp) {
        for running in runningApps(app) { running.terminate() }
    }

    func runningApps(atPath path: String) -> [NSRunningApplication] {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == target }
    }

    func canQuit(path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !target.hasPrefix("/System/Library/CoreServices/"),
              target != Bundle.main.bundleURL.standardizedFileURL.path else { return false }
        return runningApps(atPath: target).contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    func quit(path: String, force: Bool) {
        guard canQuit(path: path) else { return }
        for running in runningApps(atPath: path) where running.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if force { running.forceTerminate() } else { running.terminate() }
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshRunning()
        }
    }

    func uninstaller(mode: RemovalMode) -> AppUninstaller {
        AppUninstaller(trashMover: WorkspaceTrashMover(), mode: mode) { app in
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == app.path }
        }
    }

    func uninstall(_ app: InstalledApp, removeApp: Bool, items: [RelatedItem], mode: RemovalMode) async -> UninstallResult {
        let tool = uninstaller(mode: mode)
        let bytes = sizes[app.path] ?? 0
        let result = await Task.detached(priority: .userInitiated) {
            await tool.uninstall(app, appBytes: bytes, removeApp: removeApp, items: items)
        }.value
        let gone = Set(result.removed.map(\.path))
        if result.appRemoved {
            withAnimation(Motion.smooth) {
                apps.removeAll { $0.path == app.path }
                sizes[app.path] = nil
            }
            related[app.path] = nil
        } else if let cached = related[app.path] {
            related[app.path] = cached.filter { !gone.contains($0.path) }
        }
        refreshRunning()
        return result
    }
}

struct WorkspaceTrashMover: TrashMover {
    func trash(_ url: URL) throws -> URL? {
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        } catch {
            guard !Thread.isMainThread else { throw error }
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var moved: URL?
            nonisolated(unsafe) var failure: Error?
            NSWorkspace.shared.recycle([url]) { urls, err in
                moved = urls[url]
                failure = err
                done.signal()
            }
            done.wait()
            if let failure { throw failure }
            return moved
        }
    }
}
