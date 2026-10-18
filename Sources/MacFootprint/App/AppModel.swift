import AppKit
import FootprintCore
import Foundation
import os
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, assistant, candidates, memory, performance, applications, battery, network, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Home"
        case .assistant: return "Ask Your Mac"
        case .candidates: return "Storage"
        case .memory: return "Memory"
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .battery: return "Battery"
        case .network: return "Network"
        case .settings: return "Settings"
        }
    }

    var hint: String {
        switch self {
        case .dashboard: return "Disk space at a glance"
        case .assistant: return "Ask questions about your Mac in plain words"
        case .candidates: return "Disk space, cleanup and scan history"
        case .memory: return "What is using memory and whether it is a problem"
        case .performance: return "What is keeping your Mac busy"
        case .applications: return "Installed apps and the data they keep"
        case .battery: return "Charge, charging and battery use over time"
        case .network: return "Whether your connection works and how fast it answers"
        case .settings: return "Appearance and cleanup options"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .assistant: return "sparkles"
        case .candidates: return "internaldrive"
        case .memory: return "memorychip"
        case .performance: return "gauge.with.needle"
        case .applications: return "square.grid.2x2"
        case .battery: return "battery.75percent"
        case .network: return "network"
        case .settings: return "gearshape"
        }
    }
}

enum ScanState {
    case idle
    case scanning(ScanProgress)
}

@MainActor
final class AppModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.macfootprint.app", category: "app")

    let settings: AppSettings
    let history: HistoryStore

    @Published var selection: SidebarItem? = .dashboard
    @Published var storageTab: StorageTab = .overview
    @Published var scanState: ScanState = .idle
    @Published var scan: ScanResult?
    @Published var scanIsStale = false
    @Published var candidates: [CleanupCandidate] = []
    @Published var dockerStatus: DockerStatus?
    @Published var volume: VolumeInfo? = VolumeInfo.current(for: PathTools.home)

    @Published var planIDs: Set<UUID> = []
    @Published var planGoalBytes: Int64?
    @Published var planNotes: [String] = []
    @Published var isCleaning = false
    @Published var cleanupProgress: (Int, Int) = (0, 0)
    @Published var lastCleanup: CleanupRunResult?
    @Published var trashBytes: Int64 = 0
    @Published var isEmptyingTrash = false

    @Published var sessions: [ScanSessionSummary] = []
    @Published var cleanupRuns: [CleanupRunSummary] = []
    @Published var latestComparison: ScanComparison?
    @Published var lastCategoryTotals: [StorageCategory: Int64] = [:]
    @Published var errorMessage: String?
    private var userUnchecked: Set<String> = []

    private var scanTask: Task<Void, Never>?

    init(settings: AppSettings, history: HistoryStore = HistoryStore()) {
        self.settings = settings
        self.history = history
        Task { await self.startup() }
    }

    var isScanning: Bool {
        if case .scanning = scanState { return true }
        return false
    }

    var planItems: [CleanupCandidate] { candidates.filter { planIDs.contains($0.id) } }
    var planSummary: PlanSummary { CleanupPlanner.summarize(planItems) }

    var candidateBytes: Int64 {
        CleanupPlanner.summarize(candidates.filter(\.isSelectable)).totalBytes
    }

    func candidate(at path: String) -> CleanupCandidate? {
        candidates.first { $0.path == path }
    }

    private func startup() async {
        do {
            try await history.prune(olderThanDays: settings.historyRetentionDays)
        } catch {
            errorMessage = "Could not open local history: \(error.localizedDescription)"
        }
        await loadHistory()
        if let note = await history.recoveryNote { errorMessage = note }
    }

    func refreshVolume() {
        volume = VolumeInfo.current(for: PathTools.home)
    }

    func startScan() {
        guard !isScanning else { return }
        let roots = settings.effectiveScanRoots
        guard !roots.isEmpty else {
            errorMessage = "Add at least one folder to scan in Settings."
            return
        }
        let request = ScanRequest(
            roots: roots,
            ignoredPaths: settings.ignoredPaths,
            protectedPaths: ScanRequest.defaultProtectedPaths(includeAppContainers: settings.includeAppContainers)
        )
        let devRoots = settings.developerRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        let ignored = settings.ignoredPaths
        let running = Self.runningBundleIDsSync()
        scanState = .scanning(ScanProgress(phase: .discovering))
        lastCleanup = nil

        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            guard let model = self else { return }
            Task { @MainActor in model.applyProgress(progress) }
        }

        scanTask = Task.detached(priority: .utility) { [weak self] in
            let scanner = FilesystemScanner()
            let result = await scanner.scan(request, progress: onProgress)

            await self?.setPhase(.classifying, items: result.scannedItemCount)
            let context = DetectionContext(scan: result, developerRoots: devRoots, ignoredPaths: ignored, runningBundleIDs: running)
            var found = await DetectorRegistry.standard().run(context)

            var docker: DockerStatus? = nil
            if !Task.isCancelled {
                await self?.setPhase(.inspectingTools, items: result.scannedItemCount)
                let status = DockerInspector().inspect()
                docker = status
                if case .available(_, let rows) = status {
                    found.append(contentsOf: DockerUsageDetector().candidates(from: rows))
                }
            }

            await self?.setPhase(.saving, items: result.scannedItemCount)
            await self?.finishScan(result, candidates: found, docker: docker)
        }
    }

    private func applyProgress(_ progress: ScanProgress) {
        guard isScanning else { return }
        scanState = .scanning(progress)
    }

    private func setPhase(_ phase: ScanPhase, items: Int) {
        guard isScanning else { return }
        scanState = .scanning(ScanProgress(phase: phase, itemsVisited: items))
    }

    private func finishScan(_ result: ScanResult, candidates found: [CleanupCandidate], docker: DockerStatus?) async {
        scan = result
        scanIsStale = false
        dockerStatus = docker
        let keptPaths = Set(planItems.map(\.path))
        candidates = found
        let auto = CleanupPlanner.suggest(goalBytes: nil, candidates: found.filter { !userUnchecked.contains($0.path) }, ignoredPaths: settings.ignoredPaths)
        planIDs = Set(found.filter { keptPaths.contains($0.path) && $0.isSelectable }.map(\.id)).union(auto.selected.map(\.id))
        planGoalBytes = nil
        planNotes = []
        refreshVolume()
        do {
            try await history.save(result, candidates: found)
        } catch {
            errorMessage = "The scan finished, but saving history failed: \(error.localizedDescription). Results are still shown."
        }
        await loadHistory()
        scanState = .idle
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func loadHistory() async {
        do {
            sessions = try await history.sessions()
            cleanupRuns = try await history.cleanupRuns()
            if sessions.count >= 2 {
                latestComparison = try await history.compare(current: sessions[0], previous: sessions[1])
            } else {
                latestComparison = nil
            }
            if let last = sessions.first {
                lastCategoryTotals = try await history.categoryTotals(last.id)
            } else {
                lastCategoryTotals = [:]
            }
        } catch {
            errorMessage = "Could not load history: \(error.localizedDescription)"
        }
    }

    func compare(_ current: ScanSessionSummary, _ previous: ScanSessionSummary) async -> ScanComparison? {
        try? await history.compare(current: current, previous: previous)
    }

    func deleteAllHistory() {
        Task {
            do {
                try await history.deleteAll()
                await loadHistory()
            } catch {
                errorMessage = "Could not delete history: \(error.localizedDescription)"
            }
        }
    }

    func resetAppData() {
        Task {
            do {
                try await history.resetDatabaseFile()
            } catch {
                errorMessage = "Could not remove the history file: \(error.localizedDescription)"
            }
            settings.resetAll()
            scan = nil
            candidates = []
            planIDs = []
            lastCleanup = nil
            await loadHistory()
        }
    }

    func togglePlan(_ candidate: CleanupCandidate) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            if planIDs.contains(candidate.id) {
                planIDs.remove(candidate.id)
                userUnchecked.insert(candidate.path)
            } else if candidate.isSelectable {
                planIDs.insert(candidate.id)
                userUnchecked.remove(candidate.path)
            }
        }
    }

    func suggestPlan(goal: Int64?) {
        let suggestion = CleanupPlanner.suggest(goalBytes: goal, candidates: candidates, ignoredPaths: settings.ignoredPaths)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            planGoalBytes = goal
            planIDs = Set(suggestion.selected.map(\.id))
            planNotes = suggestion.notes
            userUnchecked = Set(candidates.filter { $0.isSelectable && !planIDs.contains($0.id) }.map(\.path))
        }
    }

    func setPlan(_ items: [CleanupCandidate], selected: Bool) {
        let selectable = items.filter(\.isSelectable)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            if selected {
                planIDs.formUnion(selectable.map(\.id))
                userUnchecked.subtract(selectable.map(\.path))
            } else {
                planIDs.subtract(selectable.map(\.id))
                userUnchecked.formUnion(selectable.map(\.path))
            }
        }
    }

    func selectNone() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            userUnchecked.formUnion(planItems.map(\.path))
            planIDs = []
            planGoalBytes = nil
            planNotes = []
        }
    }

    func executePlan() {
        let items = planSummary.items
        guard !items.isEmpty, !isCleaning else { return }
        Task { await execute(items, goal: planGoalBytes, mode: settings.removalMode) }
    }

    var scheduledItems: [CleanupCandidate] {
        ScheduledCleanupPolicy.pick(candidates, skipping: userUnchecked, ignoredPaths: settings.ignoredPaths)
    }

    @discardableResult
    func execute(_ items: [CleanupCandidate], goal: Int64?, mode: RemovalMode) async -> CleanupRunResult? {
        guard !items.isEmpty, !isCleaning else { return nil }
        isCleaning = true
        cleanupProgress = (0, items.count)
        let executor = CleanupExecutor(mode: mode, runningBundleIDs: { AppModel.runningBundleIDsSync() })
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard let model = self else { return }
            Task { @MainActor in model.cleanupProgress = (done, total) }
        }
        let result = await Task.detached(priority: .userInitiated) {
            await executor.execute(items, goalBytes: goal, progress: onProgress)
        }.value
        await finishCleanup(result)
        return result
    }

    nonisolated static func runningBundleIDsSync() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func finishCleanup(_ result: CleanupRunResult) async {
        lastCleanup = result
        isCleaning = false
        refreshTrashSize()
        let movedIDs = Set(result.moved.map(\.candidate.id))
        candidates.removeAll { movedIDs.contains($0.id) }
        planIDs.subtract(movedIDs)
        if !movedIDs.isEmpty { scanIsStale = true }
        refreshVolume()
        do {
            try await history.saveCleanup(result)
        } catch {
            errorMessage = "Cleanup finished, but saving the record failed: \(error.localizedDescription)"
        }
        await loadHistory()
    }

    func ignore(_ path: String) {
        settings.ignore(path)
        candidates.removeAll { PathTools.isSameOrDescendant($0.path, of: path) && $0.url.isFileURL }
        planIDs = planIDs.intersection(Set(candidates.map(\.id)))
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func removeUnavailableSimulators() async -> String {
        let status = await Task.detached(priority: .userInitiated) { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "delete", "unavailable"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        }.value
        refreshVolume()
        if status == 0 {
            scanIsStale = true
            return "Removed simulators that no longer work. Scan again to see the new size."
        }
        return "Could not run the simulator tool. Make sure Xcode is installed."
    }

    func openTrash() {
        NSWorkspace.shared.open(PathTools.home.appendingPathComponent(".Trash"))
    }

    func refreshTrashSize() {
        Task {
            let size = await Task.detached(priority: .utility) { TrashEmptier().size() }.value
            trashBytes = size
        }
    }

    func emptyTrash() async -> TrashEmptyResult {
        isEmptyingTrash = true
        let result = await Task.detached(priority: .userInitiated) { TrashEmptier().empty() }.value
        isEmptyingTrash = false
        refreshVolume()
        refreshTrashSize()
        return result
    }
}
