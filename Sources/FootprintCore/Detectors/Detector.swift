import Foundation

public struct DetectionContext: @unchecked Sendable {
    public let scan: ScanResult
    public let home: URL
    public let developerRoots: [URL]
    public let ignoredPaths: [String]
    public let now: Date
    public let runningBundleIDs: Set<String>
    public let fileManager: FileManager

    public init(scan: ScanResult, home: URL = PathTools.home, developerRoots: [URL], ignoredPaths: [String], now: Date = Date(), runningBundleIDs: Set<String> = [], fileManager: FileManager = .default) {
        self.scan = scan
        self.home = home
        self.developerRoots = developerRoots
        self.ignoredPaths = ignoredPaths
        self.now = now
        self.runningBundleIDs = runningBundleIDs
        self.fileManager = fileManager
    }

    public func isIgnored(_ path: String) -> Bool {
        ignoredPaths.contains { PathTools.isSameOrDescendant(path, of: $0) }
    }

    public func node(_ url: URL) -> FileNode? {
        scan.node(at: url.standardizedFileURL.path)
    }
}

public protocol CandidateDetector: Sendable {
    var id: String { get }
    var version: Int { get }
    var name: String { get }
    func detect(in context: DetectionContext) async -> [CleanupCandidate]
}

public struct DetectorRegistry: Sendable {
    public let detectors: [any CandidateDetector]

    public init(detectors: [any CandidateDetector]) {
        self.detectors = detectors
    }

    public static func standard() -> DetectorRegistry {
        DetectorRegistry(detectors: [
            XcodeDerivedDataDetector(),
            XcodeDeviceSupportDetector(),
            SimulatorCachesDetector(),
            KnownCacheDetector(),
            AppCachesDetector(),
            ElectronCachesDetector(),
            NodeModulesDetector(),
            ProjectBuildOutputDetector(),
            DevToolCleanupDetector(),
            DevToolStorageDetector(),
            LocalModelsDetector()
        ])
    }

    public func run(_ context: DetectionContext) async -> [CleanupCandidate] {
        var all: [CleanupCandidate] = []
        for detector in detectors {
            if Task.isCancelled { break }
            all.append(contentsOf: await detector.detect(in: context))
        }
        return all
            .filter { !context.isIgnored($0.path) }
            .sorted { $0.estimatedReclaimableBytes > $1.estimatedReclaimableBytes }
    }
}

enum DetectorHelpers {
    static let recentWindow: TimeInterval = 15 * 60

    static func isRecentlyModified(_ date: Date?, now: Date, window: TimeInterval = recentWindow) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < window
    }

    static func children(of url: URL, fm: FileManager) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }
}
