import XCTest
@testable import FootprintCore

final class DetectorTests: XCTestCase {
    private func context(_ tree: TempTree, devRoots: [URL] = [], running: Set<String> = []) async -> DetectionContext {
        let scan = await tree.scan()
        return DetectionContext(scan: scan, home: tree.root, developerRoots: devRoots, ignoredPaths: [], runningBundleIDs: running)
    }

    func testNodeModulesWithLockfileIsHighConfidence() async throws {
        let tree = try TempTree()
        try tree.file("code/app/package.json", bytes: 10)
        try tree.file("code/app/package-lock.json", bytes: 10)
        try tree.file("code/app/node_modules/pkg/index.js", bytes: 5_000)
        try tree.setModified("code/app/node_modules", ago: 86_400 * 3)

        let ctx = await context(tree, devRoots: [tree.root.appendingPathComponent("code")])
        let found = await NodeModulesDetector().detect(in: ctx)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].confidence, .high)
        XCTAssertEqual(found[0].eligibility, .eligible)
        XCTAssertFalse(found[0].consequences.isEmpty)
        XCTAssertEqual(found[0].detectorID, "node.node-modules")
    }

    func testNodeModulesWithoutManifestIsInformationalOnly() async throws {
        let tree = try TempTree()
        try tree.file("code/mystery/node_modules/x.js", bytes: 5_000)
        let ctx = await context(tree, devRoots: [tree.root.appendingPathComponent("code")])
        let found = await NodeModulesDetector().detect(in: ctx)

        XCTAssertEqual(found.first?.confidence, .low)
        XCTAssertEqual(found.first?.eligibility, .informationalOnly)
        XCTAssertFalse(found.first?.isSelectable ?? true)
    }

    func testNodeModulesOutsideDevRootsIsIgnored() async throws {
        let tree = try TempTree()
        try tree.file("elsewhere/app/package.json", bytes: 10)
        try tree.file("elsewhere/app/node_modules/x.js", bytes: 5_000)
        let ctx = await context(tree, devRoots: [tree.root.appendingPathComponent("code")])
        let found = await NodeModulesDetector().detect(in: ctx)
        XCTAssertTrue(found.isEmpty)
    }

    func testNestedNodeModulesNotDoubleCounted() async throws {
        let tree = try TempTree()
        try tree.file("code/app/package.json", bytes: 10)
        try tree.file("code/app/yarn.lock", bytes: 10)
        try tree.file("code/app/node_modules/a/node_modules/b/x.js", bytes: 5_000)
        let ctx = await context(tree, devRoots: [tree.root.appendingPathComponent("code")])
        let found = await NodeModulesDetector().detect(in: ctx)
        XCTAssertEqual(found.count, 1)
    }

    func testDerivedDataDetectionAndXcodeRunningDowngrade() async throws {
        let tree = try TempTree()
        let name = "MyApp-abcdefghijklmnopqrstuvwxyzab"
        try tree.file("Library/Developer/Xcode/DerivedData/\(name)/Build/out.o", bytes: 5_000)
        try tree.setModified("Library/Developer/Xcode/DerivedData/\(name)", ago: 3_600)

        var ctx = await context(tree)
        var found = await XcodeDerivedDataDetector().detect(in: ctx)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].confidence, .high)
        XCTAssertEqual(found[0].eligibility, .eligible)

        ctx = await context(tree, running: [XcodeDerivedDataDetector.xcodeBundleID])
        found = await XcodeDerivedDataDetector().detect(in: ctx)
        XCTAssertEqual(found[0].eligibility, .needsUserReview)
    }

    func testUnrecognizedDerivedDataChildIsMediumConfidence() async throws {
        let tree = try TempTree()
        try tree.file("Library/Developer/Xcode/DerivedData/weird/x.o", bytes: 5_000)
        try tree.setModified("Library/Developer/Xcode/DerivedData/weird", ago: 3_600)
        let found = await XcodeDerivedDataDetector().detect(in: await context(tree))
        XCTAssertEqual(found.first?.confidence, .medium)
    }

    func testKnownCacheIsDetectedButUnknownCacheIsNot() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/Homebrew/downloads/x.tar.gz", bytes: 5_000)
        try tree.file("Library/Caches/com.example.random/blob", bytes: 5_000)
        try tree.setModified("Library/Caches/Homebrew", ago: 3_600)
        let found = await KnownCacheDetector().detect(in: await context(tree))

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].title, "Homebrew download cache")
    }

    func testLocalModelsAreNeverCleanupCandidates() async throws {
        let tree = try TempTree()
        try tree.file(".ollama/models/blobs/sha256-x", bytes: 5_000)
        let found = await LocalModelsDetector().detect(in: await context(tree))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].eligibility, .informationalOnly)
        XCTAssertFalse(found[0].isSelectable)
    }

    func testNodeModulesFoundAnywhereInHomeWithoutDevRoots() async throws {
        let tree = try TempTree()
        try tree.file("work/app/package.json", bytes: 10)
        try tree.file("work/app/yarn.lock", bytes: 10)
        try tree.file("work/app/node_modules/x.js", bytes: 5_000)
        try tree.file("Library/thing/node_modules/x.js", bytes: 5_000)
        try tree.setModified("work/app/node_modules", ago: 86_400)
        let found = await NodeModulesDetector().detect(in: await context(tree))
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["node_modules"])
        XCTAssertTrue(found[0].path.contains("/work/app/"))
    }

    func testBuildOutputNeedsProjectMarker() async throws {
        let tree = try TempTree()
        try tree.file("code/web/package.json", bytes: 10)
        try tree.file("code/web/.next/cache/a.bin", bytes: 5_000)
        try tree.file("code/rust/Cargo.toml", bytes: 10)
        try tree.file("code/rust/target/debug/app", bytes: 5_000)
        try tree.file("code/notrust/target/keep.txt", bytes: 5_000)
        try tree.setModified("code/web/.next", ago: 86_400)
        try tree.setModified("code/rust/target", ago: 86_400)
        let found = await ProjectBuildOutputDetector(minimumBytes: 1).detect(in: await context(tree))
        XCTAssertEqual(Set(found.map { $0.url.deletingLastPathComponent().lastPathComponent }), ["web", "rust"])
        XCTAssertTrue(found.allSatisfy { $0.canBeAutoSuggested })
    }

    func testAppCachesSkipAppleAndDowngradeWhenOwnerRunning() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/com.example.editor/blob", bytes: 5_000)
        try tree.file("Library/Caches/com.apple.Safari/blob", bytes: 5_000)
        try tree.setModified("Library/Caches/com.example.editor", ago: 86_400)
        var found = await AppCachesDetector(minimumBytes: 1).detect(in: await context(tree))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].eligibility, .eligible)

        found = await AppCachesDetector(minimumBytes: 1).detect(in: await context(tree, running: ["com.example.editor"]))
        XCTAssertEqual(found[0].eligibility, .needsUserReview)
    }

    func testDevToolStorageIsHandoffOnly() async throws {
        let tree = try TempTree()
        try tree.file(".android/avd/Pixel.avd/disk.img", bytes: 5_000)
        let found = await DevToolStorageDetector(minimumBytes: 1).detect(in: await context(tree))
        XCTAssertEqual(found.count, 1)
        XCTAssertFalse(found[0].isSelectable)
        XCTAssertNotNil(found[0].handoffHint)
    }

    func testDevToolPartsKeepNewestAndDefault() async throws {
        let tree = try TempTree()
        for v in ["23.1.7779620", "26.1.10909125", "27.1.12297006"] {
            try tree.file("Library/Android/sdk/ndk/\(v)/x", bytes: 5_000)
            try tree.setModified("Library/Android/sdk/ndk/\(v)", ago: 86_400)
        }
        for v in ["v18.20.8", "v20.15.1", "v24.14.0", "v26.8.2"] {
            try tree.file(".nvm/versions/node/\(v)/bin/node", bytes: 5_000)
            try tree.setModified(".nvm/versions/node/\(v)", ago: 86_400)
        }
        try tree.file(".nvm/alias/default", bytes: 0)
        try "24".write(to: tree.root.appendingPathComponent(".nvm/alias/default"), atomically: true, encoding: .utf8)
        try tree.file(".android/avd/Pixel.avd/snapshots/default_boot/ram.bin", bytes: 5_000)
        try tree.setModified(".android/avd/Pixel.avd/snapshots", ago: 86_400)

        let found = await DevToolCleanupDetector(minimumBytes: 1).detect(in: await context(tree))
        let names = Set(found.map(\.url.lastPathComponent))
        XCTAssertTrue(names.contains("23.1.7779620"))
        XCTAssertTrue(names.contains("26.1.10909125"))
        XCTAssertFalse(names.contains("27.1.12297006"))
        XCTAssertTrue(names.contains("v18.20.8"))
        XCTAssertTrue(names.contains("v20.15.1"))
        XCTAssertFalse(names.contains("v24.14.0"))
        XCTAssertFalse(names.contains("v26.8.2"))
        XCTAssertEqual(found.first { $0.url.lastPathComponent == "snapshots" }?.eligibility, .eligible)
        XCTAssertTrue(found.allSatisfy { $0.isSelectable })
    }

    func testDockerOutputParsing() {
        let output = """
        {"Active":"2","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"0B","Size":"512MB","TotalCount":"3","Type":"Local Volumes"}
        """
        let rows = DockerInspector.parse(output)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sizeBytes, 2_400_000_000)
        XCTAssertEqual(rows[0].reclaimableBytes, 1_200_000_000)
        let candidates = DockerUsageDetector().candidates(from: rows)
        XCTAssertTrue(candidates.allSatisfy { !$0.isSelectable })
        XCTAssertEqual(candidates.first { $0.title.contains("Volumes") }?.riskLevel, .high)
    }
}
