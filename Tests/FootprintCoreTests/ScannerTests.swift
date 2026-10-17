import XCTest
@testable import FootprintCore

final class ScannerTests: XCTestCase {
    func testSizesAggregateUpTheTree() async throws {
        let tree = try TempTree()
        try tree.file("a/one.bin", bytes: 10_000)
        try tree.file("a/b/two.bin", bytes: 20_000)
        let result = await tree.scan()

        let a = try XCTUnwrap(result.node(at: tree.root.appendingPathComponent("a").path))
        XCTAssertEqual(a.logicalSize, 30_000)
        XCTAssertGreaterThanOrEqual(a.allocatedSize, 30_000)
        XCTAssertEqual(result.status, .completed)
    }

    func testSymlinksAreNotFollowed() async throws {
        let tree = try TempTree()
        try tree.file("real/big.bin", bytes: 50_000)
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("link"), withDestinationURL: tree.root.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("real/loop"), withDestinationURL: tree.root)
        let result = await tree.scan()

        XCTAssertEqual(result.coverage.symlinksNotFollowed, 2)
        XCTAssertLessThan(result.roots[0].logicalSize, 100_000)
    }

    func testHardLinksCountedOnce() async throws {
        let tree = try TempTree()
        let original = try tree.file("x/data.bin", bytes: 40_000)
        try FileManager.default.linkItem(at: original, to: tree.root.appendingPathComponent("x/data-link.bin"))
        let result = await tree.scan()

        XCTAssertEqual(result.coverage.hardLinkDuplicatesSkipped, 1)
        XCTAssertLessThan(result.roots[0].allocatedSize, 80_000)
    }

    func testIgnoredAndProtectedPathsAreSkippedAndReported() async throws {
        let tree = try TempTree()
        try tree.file("keep/a.bin", bytes: 1_000)
        try tree.file("skip/b.bin", bytes: 1_000)
        try tree.file("private/c.bin", bytes: 1_000)
        let result = await tree.scan(
            ignored: [tree.root.appendingPathComponent("skip").path],
            protected: [tree.root.appendingPathComponent("private").path]
        )

        XCTAssertNil(result.node(at: tree.root.appendingPathComponent("skip").path))
        XCTAssertNil(result.node(at: tree.root.appendingPathComponent("private").path))
        XCTAssertTrue(result.coverage.skipped.contains { $0.reason == .ignoredByUser })
        XCTAssertTrue(result.coverage.skipped.contains { $0.reason == .protectedByDefault })
        XCTAssertEqual(result.status, .partial)
    }

    func testUnreadableFolderIsReportedNotCrashing() async throws {
        let tree = try TempTree()
        let locked = try tree.dir("locked")
        try tree.file("locked/secret.bin", bytes: 1_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = await tree.scan()
        XCTAssertTrue(result.coverage.skipped.contains { $0.reason == .permissionDenied })
        XCTAssertEqual(result.coverage.roots.first?.state, .partial)
    }

    func testMissingRootIsReported() async {
        let request = ScanRequest(roots: [URL(fileURLWithPath: "/definitely/not/here-\(UUID())")])
        let result = await FilesystemScanner().scan(request)
        XCTAssertEqual(result.coverage.roots.first?.state, .missing)
    }

    func testCancellationStopsScan() async throws {
        let tree = try TempTree()
        for i in 0..<50 { try tree.file("d\(i)/f.bin", bytes: 100) }
        let task = Task { await tree.scan() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.status, .cancelled)
    }

    func testNestedRootsAreDeduplicated() {
        let roots = ScanRequest.normalizedRoots([URL(fileURLWithPath: "/tmp/a/b"), URL(fileURLWithPath: "/tmp/a")])
        XCTAssertEqual(roots.count, 1)
    }

    func testCategoryClassification() {
        let home = URL(fileURLWithPath: "/Users/test")
        let c = CategoryClassifier(home: home)
        XCTAssertEqual(c.category(forPath: "/Users/test/Library/Developer/Xcode", name: "Xcode", kind: .directory), .developerArtifacts)
        XCTAssertEqual(c.category(forPath: "/Users/test/code/app/node_modules", name: "node_modules", kind: .directory), .developerArtifacts)
        XCTAssertEqual(c.category(forPath: "/Users/test/.ollama/models", name: "models", kind: .directory), .localAIModels)
        XCTAssertEqual(c.category(forPath: "/Applications/Foo.app", name: "Foo.app", kind: .package), .applications)
        XCTAssertNil(c.category(forPath: "/Users/test/random", name: "random", kind: .directory))
    }
}
