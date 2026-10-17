import Foundation
@testable import FootprintCore

final class TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mf-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func setModified(_ relative: String, ago seconds: TimeInterval) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    func scan(ignored: [String] = [], protected: [String] = []) async -> ScanResult {
        let request = ScanRequest(roots: [root], ignoredPaths: ignored, protectedPaths: protected, keepFileThreshold: 1, foldDirectoryThreshold: 0, collapseDirectoryThreshold: 0)
        return await FilesystemScanner(classifier: CategoryClassifier(home: root)).scan(request)
    }
}

func makeCandidate(
    path: String,
    bytes: Int64 = 1_000,
    confidence: Confidence = .high,
    eligibility: Eligibility = .eligible,
    risk: RiskLevel = .low,
    detector: String = "test.detector",
    identity: ItemIdentity? = nil
) -> CleanupCandidate {
    let url = URL(fileURLWithPath: path)
    return CleanupCandidate(
        detectorID: detector,
        detectorVersion: 1,
        url: url,
        title: url.lastPathComponent,
        itemKind: .directory,
        logicalSizeBytes: bytes,
        allocatedSizeBytes: bytes,
        classification: .cache,
        source: .caches,
        confidence: confidence,
        confidenceReasons: ["test"],
        eligibility: eligibility,
        riskLevel: risk,
        riskEvidence: [],
        reason: "test",
        consequences: ["test consequence"],
        actionType: .moveToTrash,
        reversibility: .expected,
        lastModified: nil,
        identity: identity ?? ItemIdentity.read(url)
    )
}
