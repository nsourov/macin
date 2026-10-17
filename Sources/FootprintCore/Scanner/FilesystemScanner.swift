import Darwin
import Foundation
import os

public struct ScanRequest: Sendable {
    public var roots: [URL]
    public var ignoredPaths: [String]
    public var protectedPaths: [String]
    public var keepFileThreshold: Int64
    public var foldDirectoryThreshold: Int64
    public var collapseDirectoryThreshold: Int64

    public init(
        roots: [URL],
        ignoredPaths: [String] = [],
        protectedPaths: [String] = [],
        keepFileThreshold: Int64 = 1_000_000,
        foldDirectoryThreshold: Int64 = 100_000,
        collapseDirectoryThreshold: Int64 = 1_000_000
    ) {
        self.roots = roots
        self.ignoredPaths = ignoredPaths
        self.protectedPaths = protectedPaths
        self.keepFileThreshold = keepFileThreshold
        self.foldDirectoryThreshold = foldDirectoryThreshold
        self.collapseDirectoryThreshold = collapseDirectoryThreshold
    }

    public static func defaultProtectedPaths(home: URL = PathTools.home, includeAppContainers: Bool) -> [String] {
        var paths = ["\(home.path)/.Trash", "/System", "/private/var/vm", "/Volumes", "/dev"]
        if !includeAppContainers {
            paths.append("\(home.path)/Library/Containers")
            paths.append("\(home.path)/Library/Group Containers")
        }
        return paths
    }

    public static func normalizedRoots(_ urls: [URL]) -> [URL] {
        let standardized = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        var unique: [URL] = []
        for url in standardized.sorted(by: { $0.path.count < $1.path.count }) {
            if unique.contains(where: { PathTools.isSameOrDescendant(url.path, of: $0.path) }) { continue }
            unique.append(url)
        }
        return unique
    }
}

public enum ScanPhase: String, Sendable {
    case discovering = "Discovering folders"
    case calculating = "Calculating sizes"
    case classifying = "Classifying known artifacts"
    case inspectingTools = "Inspecting developer tools"
    case saving = "Saving scan summary"
}

public struct ScanProgress: Sendable {
    public var phase: ScanPhase
    public var itemsVisited: Int
    public var bytesSeen: Int64
    public var currentRoot: String
    public var currentPath: String

    public init(phase: ScanPhase, itemsVisited: Int = 0, bytesSeen: Int64 = 0, currentRoot: String = "", currentPath: String = "") {
        self.phase = phase
        self.itemsVisited = itemsVisited
        self.bytesSeen = bytesSeen
        self.currentRoot = currentRoot
        self.currentPath = currentPath
    }
}


public final class FilesystemScanner: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.macfootprint.app", category: "scanner")
    private static let maxRecordedSkips = 500
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xpc", "appex", "qlgenerator", "mdimporter", "prefpane",
        "photoslibrary", "musiclibrary", "tvlibrary", "photoslibraryd", "xcodeproj", "xcworkspace", "xcarchive",
        "playground", "rtfd", "pages", "numbers", "key", "sparsebundle", "dSYM", "xcassets", "car", "lproj"
    ]

    private struct Outcome {
        let node: FileNode
        var error: DirectoryReadError?
        var fileLogical: Int64 = 0
        var fileAllocated: Int64 = 0
        var ownLogical: Int64 = 0
        var ownAllocated: Int64 = 0
        var itemCount = 0
        var visited = 0
        var symlinks = 0
        var bigFiles: [FileNode] = []
        var subdirs: [FileNode] = []
        var skips: [SkippedItem] = []
        var hardLinks: [RawEntry] = []
    }

    private let classifier: CategoryClassifier
    private let workerCount: Int
    private let condition = NSCondition()

    private var request = ScanRequest(roots: [])
    private var ignoredSet = Set<String>()
    private var protectedSet = Set<String>()
    private var queue: [FileNode] = []
    private var active = 0
    private var cancelled = false
    private var coverage = ScanCoverage()
    private var seenHardLinks = Set<UInt64>()
    private var rootDevices: [Int32] = []
    private var rootSkips: [Int] = []
    private var visited = 0
    private var bytesSeen: Int64 = 0
    private var lastReport = Date.distantPast
    private var progressHandler: (@Sendable (ScanProgress) -> Void)?

    public init(classifier: CategoryClassifier = CategoryClassifier(), workerCount: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))) {
        self.classifier = classifier
        self.workerCount = workerCount
    }

    public func scan(_ request: ScanRequest, progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanResult {
        let started = Date()
        reset(request, progress: progress)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        progress?(ScanProgress(phase: .discovering))

        let roots = ScanRequest.normalizedRoots(request.roots)
        var rootNodes: [FileNode] = []
        var rootStates: [(path: String, node: FileNode?, coverage: RootCoverage?)] = []

        for rootURL in roots {
            let path = rootURL.path
            if Task.isCancelled {
                rootStates.append((path, nil, RootCoverage(path: path, state: .cancelled, note: "Scan was cancelled before this location")))
                continue
            }
            if request.ignoredPaths.contains(where: { PathTools.isSameOrDescendant(path, of: $0) }) {
                rootStates.append((path, nil, RootCoverage(path: path, state: .ignored, note: "In your ignore list")))
                continue
            }
            var info = stat()
            guard lstat(path, &info) == 0 || stat(path, &info) == 0 else {
                rootStates.append((path, nil, RootCoverage(path: path, state: .missing, note: "Folder not found")))
                continue
            }
            if (info.st_mode & S_IFMT) != S_IFDIR {
                let node = FileNode(url: rootURL, kind: .file, modified: nil,
                                    logicalSize: Int64(info.st_size), allocatedSize: Int64(info.st_blocks) * 512)
                rootNodes.append(node)
                rootStates.append((path, nil, RootCoverage(path: path, state: .scanned)))
                continue
            }
            let probe = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard probe >= 0 else {
                rootStates.append((path, nil, RootCoverage(path: path, state: .inaccessible, note: "macOS denied access to this folder")))
                continue
            }
            close(probe)

            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            let node = FileNode(url: rootURL, path: path, name: nil, kind: Self.isPackage(rootURL.lastPathComponent) ? .package : .directory, modified: modified)
            node.rootIndex = rootDevices.count
            rootDevices.append(info.st_dev)
            rootSkips.append(0)
            queue.append(node)
            rootNodes.append(node)
            rootStates.append((path, node, nil))
        }

        if !queue.isEmpty {
            await withTaskCancellationHandler {
                await runWorkers()
            } onCancel: {
                self.cancel()
            }
        }

        var unfinished = Set<ObjectIdentifier>()
        for case let (_, node?, _) in rootStates where !node.isFinalized {
            unfinished.insert(ObjectIdentifier(node))
            repair(node)
        }

        coverage.roots = rootStates.map { entry in
            if let fixed = entry.coverage { return fixed }
            guard let node = entry.node else { return RootCoverage(path: entry.path, state: .missing) }
            if unfinished.contains(ObjectIdentifier(node)) {
                return RootCoverage(path: entry.path, state: .cancelled, note: "Scan was cancelled; sizes are partial")
            }
            let hadSkips = rootSkips[node.rootIndex] > 0
            return RootCoverage(path: entry.path, state: hadSkips ? .partial : .scanned, note: hadSkips ? "Some items inside could not be scanned" : nil)
        }

        let wasCancelled = cancelled || coverage.roots.contains { $0.state == .cancelled }
        progress?(ScanProgress(phase: .classifying, itemsVisited: visited, bytesSeen: bytesSeen))
        let totals = classifier.totals(for: rootNodes)
        let status: ScanStatus = wasCancelled ? .cancelled : (coverage.isComplete ? .completed : .partial)
        Self.logger.info("Scan finished: \(self.visited, privacy: .public) items in \(Date().timeIntervalSince(started), privacy: .public)s, status \(status.rawValue, privacy: .public)")

        return ScanResult(
            id: UUID(),
            startedAt: started,
            finishedAt: Date(),
            status: status,
            roots: rootNodes,
            coverage: coverage,
            volume: VolumeInfo.current(for: roots.first ?? URL(fileURLWithPath: "/")),
            categoryTotals: totals,
            scannedItemCount: visited,
            rootSetHash: PathTools.rootSetHash(roots.map(\.path))
        )
    }

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packageExtensions.contains(String(name[name.index(after: dot)...]))
    }

    private func reset(_ request: ScanRequest, progress: (@Sendable (ScanProgress) -> Void)?) {
        self.request = request
        ignoredSet = Set(request.ignoredPaths)
        protectedSet = Set(request.protectedPaths)
        queue = []
        active = 0
        cancelled = false
        coverage = ScanCoverage()
        seenHardLinks = []
        rootDevices = []
        rootSkips = []
        visited = 0
        bytesSeen = 0
        lastReport = .distantPast
        progressHandler = progress
    }

    private func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    private func runWorkers() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in 0..<workerCount {
                group.enter()
                let thread = Thread { [self] in
                    workerLoop()
                    group.leave()
                }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }
    }

    private func workerLoop() {
        let reader = BulkDirectoryReader()
        while true {
            condition.lock()
            while queue.isEmpty && active > 0 && !cancelled { condition.wait() }
            if cancelled || queue.isEmpty {
                condition.broadcast()
                condition.unlock()
                return
            }
            let node = queue.removeLast()
            active += 1
            condition.unlock()

            let outcome = read(node, reader: reader)

            condition.lock()
            apply(outcome)
            active -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    private func read(_ node: FileNode, reader: BulkDirectoryReader) -> Outcome {
        var out = Outcome(node: node)
        let entries: [RawEntry]
        do {
            entries = try reader.read(node.path)
        } catch let error as DirectoryReadError {
            out.error = error
            return out
        } catch {
            out.error = .other(0)
            return out
        }

        let rootDevice = rootDevices[node.rootIndex]
        let checkPaths = !ignoredSet.isEmpty || !protectedSet.isEmpty
        let base = node.path == "/" ? "" : node.path

        for entry in entries {
            var childPath: String?
            if checkPaths || entry.kind == .directory {
                let p = base + "/" + entry.name
                childPath = p
                if ignoredSet.contains(p) {
                    out.skips.append(SkippedItem(path: p, reason: .ignoredByUser))
                    continue
                }
                if protectedSet.contains(p) {
                    out.skips.append(SkippedItem(path: p, reason: .protectedByDefault))
                    continue
                }
            }
            out.visited += 1

            switch entry.kind {
            case .symlink:
                out.symlinks += 1
                out.itemCount += 1
                out.fileLogical += entry.logicalSize
                out.fileAllocated += entry.allocatedSize
                out.ownLogical += entry.logicalSize
                out.ownAllocated += entry.allocatedSize
            case .directory:
                let path = childPath ?? (base + "/" + entry.name)
                if entry.device != rootDevice {
                    out.skips.append(SkippedItem(path: path, reason: .otherVolume))
                    continue
                }
                let url = node.url.appendingPathComponent(entry.name, isDirectory: true)
                let child = FileNode(url: url, path: path, name: entry.name,
                                     kind: Self.isPackage(entry.name) ? .package : .directory, modified: entry.modified)
                child.rootIndex = node.rootIndex
                out.subdirs.append(child)
            case .file, .other:
                if entry.linkCount > 1 {
                    out.hardLinks.append(entry)
                    continue
                }
                addFile(entry, to: &out)
            }
        }
        return out
    }

    private func addFile(_ entry: RawEntry, to out: inout Outcome) {
        out.itemCount += 1
        out.fileLogical += entry.logicalSize
        out.fileAllocated += entry.allocatedSize
        if entry.allocatedSize >= request.keepFileThreshold || entry.logicalSize >= request.keepFileThreshold {
            let node = out.node
            let url = node.url.appendingPathComponent(entry.name, isDirectory: false)
            let base = node.path == "/" ? "" : node.path
            let file = FileNode(url: url, path: base + "/" + entry.name, name: entry.name, kind: .file, modified: entry.modified,
                                logicalSize: entry.logicalSize, allocatedSize: entry.allocatedSize)
            out.bigFiles.append(file)
        } else {
            out.ownLogical += entry.logicalSize
            out.ownAllocated += entry.allocatedSize
        }
    }

    private func recordSkip(_ item: SkippedItem, rootIndex: Int) {
        if item.reason != .ignoredByUser { rootSkips[rootIndex] += 1 }
        coverage.skippedCount += 1
        if coverage.skipped.count < Self.maxRecordedSkips { coverage.skipped.append(item) }
    }

    private func apply(_ outcome: Outcome) {
        var out = outcome
        let node = out.node

        if let error = out.error {
            node.isPartial = true
            switch error {
            case .permissionDenied: recordSkip(SkippedItem(path: node.path, reason: .permissionDenied), rootIndex: node.rootIndex)
            case .disappeared: recordSkip(SkippedItem(path: node.path, reason: .disappeared), rootIndex: node.rootIndex)
            case .other(let code): recordSkip(SkippedItem(path: node.path, reason: .readError, detail: String(cString: strerror(code))), rootIndex: node.rootIndex)
            }
        }

        for entry in out.hardLinks {
            if seenHardLinks.insert(entry.fileID).inserted {
                addFile(entry, to: &out)
            } else {
                coverage.hardLinkDuplicatesSkipped += 1
                out.itemCount += 1
                out.fileLogical += entry.logicalSize
                out.ownLogical += entry.logicalSize
            }
        }

        for skip in out.skips { recordSkip(skip, rootIndex: node.rootIndex) }
        coverage.symlinksNotFollowed += out.symlinks
        visited += out.visited
        bytesSeen += out.fileAllocated

        node.logicalSize += out.fileLogical
        node.allocatedSize += out.fileAllocated
        node.ownLogicalSize += out.ownLogical
        node.ownAllocatedSize += out.ownAllocated
        node.itemCount += out.itemCount
        for file in out.bigFiles { file.parent = node }
        node.children.append(contentsOf: out.bigFiles)

        for sub in out.subdirs { sub.parent = node }
        node.children.append(contentsOf: out.subdirs)
        node.pendingChildren = out.subdirs.count
        if cancelled {
            for sub in out.subdirs { sub.isPartial = true }
            node.isPartial = node.isPartial || !out.subdirs.isEmpty
        } else {
            queue.append(contentsOf: out.subdirs)
        }

        if out.subdirs.isEmpty { finalizeUpward(node) }

        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.1 {
            lastReport = now
            progressHandler?(ScanProgress(phase: .calculating, itemsVisited: visited, bytesSeen: bytesSeen,
                                          currentRoot: "", currentPath: node.path))
        }
    }

    private func finalizeUpward(_ start: FileNode) {
        var current = start
        while true {
            finalizeNode(current)
            guard let parent = current.parent else { return }
            parent.logicalSize += current.logicalSize
            parent.allocatedSize += current.allocatedSize
            parent.itemCount += current.itemCount + 1
            if current.isPartial { parent.isPartial = true }
            parent.pendingChildren -= 1
            if parent.pendingChildren > 0 { return }
            current = parent
        }
    }

    private func finalizeNode(_ node: FileNode) {
        var kept: [FileNode] = []
        kept.reserveCapacity(node.children.count)
        for child in node.children {
            guard child.isContainer else {
                kept.append(child)
                continue
            }
            if child.allocatedSize < request.foldDirectoryThreshold && !child.isPartial && child.name != "node_modules" {
                node.ownLogicalSize += child.logicalSize
                node.ownAllocatedSize += child.allocatedSize
                continue
            }
            if child.allocatedSize < request.collapseDirectoryThreshold && !child.isPartial {
                child.ownLogicalSize = child.logicalSize
                child.ownAllocatedSize = child.allocatedSize
                child.children = []
            }
            kept.append(child)
        }
        kept.sort { $0.allocatedSize > $1.allocatedSize }
        node.children = kept
        node.isFinalized = true
    }

    private func repair(_ node: FileNode) {
        guard !node.isFinalized else { return }
        node.isPartial = true
        for child in node.children where child.isContainer && !child.isFinalized {
            repair(child)
            node.logicalSize += child.logicalSize
            node.allocatedSize += child.allocatedSize
            node.itemCount += child.itemCount + 1
        }
        finalizeNode(node)
    }
}
