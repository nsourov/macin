import XCTest
@testable import FootprintCore

private struct FailingTrash: TrashMover {
    func trash(_ url: URL) throws -> URL? {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

private final class RecordingTrash: TrashMover, @unchecked Sendable {
    var moved: [URL] = []
    let destination: URL

    init(destination: URL) {
        self.destination = destination
    }

    func trash(_ url: URL) throws -> URL? {
        let target = destination.appendingPathComponent(url.lastPathComponent + "-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: target)
        moved.append(url)
        return target
    }
}

final class PlannerTests: XCTestCase {
    func testSuggestionPrefersLowRiskHighConfidenceAndStopsAtGoal() {
        let a = makeCandidate(path: "/u/a", bytes: 6_000, confidence: .high, risk: .low)
        let b = makeCandidate(path: "/u/b", bytes: 9_000, confidence: .medium, risk: .medium)
        let c = makeCandidate(path: "/u/c", bytes: 5_000, confidence: .high, risk: .low)
        let s = CleanupPlanner.suggest(goalBytes: 10_000, candidates: [a, b, c])

        XCTAssertEqual(Set(s.selected.map(\.path)), ["/u/a", "/u/c"])
        XCTAssertEqual(s.shortfallBytes, 0)
    }

    func testLowConfidenceAndReviewItemsNeverAutoSelected() {
        let low = makeCandidate(path: "/u/low", bytes: 50_000, confidence: .low)
        let review = makeCandidate(path: "/u/review", bytes: 50_000, eligibility: .needsUserReview)
        let info = makeCandidate(path: "/u/info", bytes: 50_000, eligibility: .informationalOnly)
        let s = CleanupPlanner.suggest(goalBytes: 10_000, candidates: [low, review, info])

        XCTAssertTrue(s.selected.isEmpty)
        XCTAssertEqual(s.shortfallBytes, 10_000)
        XCTAssertFalse(s.notes.isEmpty)
    }

    func testOverlappingCandidatesNotDoubleCounted() {
        let parent = makeCandidate(path: "/u/cache", bytes: 10_000)
        let child = makeCandidate(path: "/u/cache/sub", bytes: 4_000)
        let summary = CleanupPlanner.summarize([parent, child])

        XCTAssertEqual(summary.items.map(\.path), ["/u/cache"])
        XCTAssertEqual(summary.totalBytes, 10_000)
        XCTAssertEqual(summary.overlapping.count, 1)

        let s = CleanupPlanner.suggest(goalBytes: nil, candidates: [parent, child])
        XCTAssertEqual(s.selected.count, 1)
    }

    func testIgnoredPathsExcluded() {
        let a = makeCandidate(path: "/u/a", bytes: 6_000)
        let s = CleanupPlanner.suggest(goalBytes: nil, candidates: [a], ignoredPaths: ["/u"])
        XCTAssertTrue(s.selected.isEmpty)
    }
}

final class ExecutorTests: XCTestCase {
    private func setup() throws -> (TempTree, SafetyPolicy, URL) {
        let tree = try TempTree()
        let trash = try tree.dir("FakeTrash")
        return (tree, SafetyPolicy(home: tree.root), trash)
    }

    func testOnlyApprovedRevalidatedItemsAreMoved() async throws {
        let (tree, policy, trashDir) = try setup()
        let approved = try tree.dir("cache/approved")
        try tree.file("cache/approved/x.bin", bytes: 100)
        let untouched = try tree.file("cache/other/y.bin", bytes: 100)

        let mover = RecordingTrash(destination: trashDir)
        let executor = CleanupExecutor(policy: policy, trashMover: mover, volumeURL: tree.root)
        let result = await executor.execute([makeCandidate(path: approved.path)], goalBytes: nil)

        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(mover.moved.map(\.path), [approved.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: approved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testPermanentModeDeletesWithoutTrash() async throws {
        let (tree, policy, trashDir) = try setup()
        let item = try tree.dir("cache/item")
        try tree.file("cache/item/x.bin", bytes: 100)
        let untouched = try tree.file("cache/other/y.bin", bytes: 100)

        let mover = RecordingTrash(destination: trashDir)
        let executor = CleanupExecutor(policy: policy, trashMover: mover, volumeURL: tree.root, mode: .permanent)
        let result = await executor.execute([makeCandidate(path: item.path)], goalBytes: nil)

        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertTrue(mover.moved.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testPermanentModeStillSkipsChangedItems() async throws {
        let (tree, policy, trashDir) = try setup()
        let item = try tree.dir("cache/item")
        let candidate = makeCandidate(path: item.path)
        try FileManager.default.removeItem(at: item)
        try tree.dir("cache/item")

        let executor = CleanupExecutor(policy: policy, trashMover: RecordingTrash(destination: trashDir), volumeURL: tree.root, mode: .permanent)
        let result = await executor.execute([candidate], goalBytes: nil)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testTrashFailureNeverDeletes() async throws {
        let (tree, policy, _) = try setup()
        let item = try tree.dir("cache/item")
        try tree.file("cache/item/x.bin", bytes: 100)

        let executor = CleanupExecutor(policy: policy, trashMover: FailingTrash(), volumeURL: tree.root)
        let result = await executor.execute([makeCandidate(path: item.path)], goalBytes: nil)

        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.appendingPathComponent("x.bin").path))
        XCTAssertTrue(result.failed[0].message.contains("Nothing was deleted"))
    }

    func testReplacedItemIsSkipped() async throws {
        let (tree, policy, trashDir) = try setup()
        let item = try tree.dir("cache/item")
        let candidate = makeCandidate(path: item.path)
        try FileManager.default.removeItem(at: item)
        try tree.dir("cache/item")

        let executor = CleanupExecutor(policy: policy, trashMover: RecordingTrash(destination: trashDir), volumeURL: tree.root)
        let result = await executor.execute([candidate], goalBytes: nil)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testChangedItemIsSkipped() async throws {
        let (tree, policy, trashDir) = try setup()
        let item = try tree.dir("cache/item")
        try tree.setModified("cache/item", ago: 3_600)
        let candidate = makeCandidate(path: item.path)
        try tree.file("cache/item/new.bin", bytes: 10)

        let executor = CleanupExecutor(policy: policy, trashMover: RecordingTrash(destination: trashDir), volumeURL: tree.root)
        let result = await executor.execute([candidate], goalBytes: nil)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].message.contains("changed"))
    }

    func testSymlinkSwapIsSkipped() async throws {
        let (tree, policy, trashDir) = try setup()
        let item = try tree.dir("cache/item")
        let candidate = makeCandidate(path: item.path)
        try FileManager.default.removeItem(at: item)
        let precious = try tree.dir("precious")
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: precious)

        let executor = CleanupExecutor(policy: policy, trashMover: RecordingTrash(destination: trashDir), volumeURL: tree.root)
        let result = await executor.execute([candidate], goalBytes: nil)
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
    }

    func testInformationalItemsCannotBeExecuted() async throws {
        let (tree, policy, trashDir) = try setup()
        let item = try tree.dir("models")
        let candidate = makeCandidate(path: item.path, eligibility: .informationalOnly)
        let executor = CleanupExecutor(policy: policy, trashMover: RecordingTrash(destination: trashDir), volumeURL: tree.root)
        let result = await executor.execute([candidate], goalBytes: nil)
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testNodeModulesWithoutManifestAtActionTimeIsSkipped() async throws {
        let (tree, policy, trashDir) = try setup()
        try tree.file("code/app/package.json", bytes: 10)
        let nm = try tree.dir("code/app/node_modules")
        let candidate = makeCandidate(path: nm.path, detector: "node.node-modules")
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("code/app/package.json"))

        let executor = CleanupExecutor(policy: policy, trashMover: RecordingTrash(destination: trashDir), volumeURL: tree.root)
        let result = await executor.execute([candidate], goalBytes: nil)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nm.path))
    }

    func testSafetyPolicyBlocksSystemAndTopLevelFolders() {
        let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/test"))
        for path in ["/System/Library", "/Library/Caches", "/Applications/Xcode.app", "/Users/test", "/Users/test/Documents", "/Users/test/Library/Caches", "/Users/other/x", "/Users/test/.Trash/x"] {
            if case .valid = policy.check(URL(fileURLWithPath: path)) {
                XCTFail("Should block \(path)")
            }
        }
        XCTAssertEqual(policy.check(URL(fileURLWithPath: "/Users/test/Library/Caches/Homebrew")), .valid)
    }
}
