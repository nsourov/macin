import XCTest
@testable import FootprintCore

final class ApplicationsTests: XCTestCase {
    private func makeApp(_ tree: TempTree, _ relative: String, id: String?, version: String = "1.0") throws -> URL {
        let app = try tree.dir(relative)
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let id { info["CFBundleIdentifier"] = id }
        let contents = try tree.dir(relative + "/Contents")
        (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        try tree.file(relative + "/Contents/MacOS/bin", bytes: 50_000)
        return app
    }

    func testDiscoversAppsOneFolderDeepAndSkipsSymlinks() throws {
        let tree = try TempTree()
        let a = try makeApp(tree, "Apps/Alpha.app", id: "com.example.alpha", version: "2.1")
        _ = try makeApp(tree, "Apps/Utilities/Beta.app", id: "com.example.beta")
        _ = try makeApp(tree, "Apps/Alpha.app/Contents/Helpers/Inner.app", id: "com.example.inner")
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("Apps/Link.app"), withDestinationURL: a)

        let result = AppDiscovery.discover(roots: [(tree.root.appendingPathComponent("Apps"), .applications)])
        XCTAssertEqual(result.apps.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(result.apps.first?.version, "2.1")
        XCTAssertEqual(result.apps.first?.bundleID, "com.example.alpha")
    }

    func testMissingBundleIDDoesNotCrash() throws {
        let tree = try TempTree()
        _ = try makeApp(tree, "Apps/NoID.app", id: nil)
        let result = AppDiscovery.discover(roots: [(tree.root.appendingPathComponent("Apps"), .applications)])
        XCTAssertEqual(result.apps.count, 1)
        XCTAssertNil(result.apps[0].bundleID)
    }

    func testAllocatedSizeCountsFiles() throws {
        let tree = try TempTree()
        let app = try makeApp(tree, "Apps/Alpha.app", id: "com.example.alpha")
        XCTAssertGreaterThanOrEqual(DiskUsage.allocatedSize(of: app), 50_000)
    }

    func testRelatedDataUsesExactIDAndSafeDefaults() throws {
        let tree = try TempTree()
        let id = "com.example.alpha"
        try tree.file("Library/Caches/\(id)/c.bin", bytes: 1_000)
        try tree.file("Library/Logs/\(id)/l.log", bytes: 100)
        try tree.file("Library/Preferences/\(id).plist", bytes: 100)
        try tree.file("Library/Application Support/\(id)/db", bytes: 100)
        try tree.file("Library/Containers/\(id)/Data/doc", bytes: 100)
        try tree.file("Library/Group Containers/TEAM123.\(id)/x", bytes: 100)
        try tree.file("Library/Caches/com.example.alphabet/x", bytes: 100)
        try tree.file("Library/Application Support/Alpha/x", bytes: 100)

        let app = InstalledApp(path: "/Applications/Alpha.app", name: "Alpha", bundleID: id, version: nil, location: .applications, modified: nil)
        let items = RelatedDataScanner.scan(for: app, home: tree.root)
        let byCategory = Dictionary(grouping: items, by: \.category)

        XCTAssertFalse(items.contains { $0.path.contains("alphabet") })
        XCTAssertEqual(byCategory[.caches]?.first?.defaultSelected, true)
        XCTAssertEqual(byCategory[.logs]?.first?.defaultSelected, true)
        XCTAssertEqual(byCategory[.preferences]?.first?.defaultSelected, false)
        XCTAssertEqual(byCategory[.containers]?.first?.risk, .userData)
        XCTAssertEqual(byCategory[.containers]?.first?.defaultSelected, false)
        XCTAssertEqual(byCategory[.groupContainers]?.first?.confidence, .medium)
        let byName = items.first { $0.path.hasSuffix("Application Support/Alpha") }
        XCTAssertEqual(byName?.confidence, .low)
        XCTAssertEqual(byName?.defaultSelected, false)
        XCTAssertEqual(items.first?.confidence, .high)
    }

    func testVendorFolderIsLikelyNotSure() throws {
        let tree = try TempTree()
        try tree.file("Library/Application Support/Google/Chrome/Default/x", bytes: 1_000)
        try tree.file("Library/Caches/Google/Chrome/y", bytes: 1_000)
        try tree.file("Library/Application Support/Google/Drive/z", bytes: 1_000)

        let app = InstalledApp(path: "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome", version: nil, location: .applications, modified: nil)
        let items = RelatedDataScanner.scan(for: app, home: tree.root)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.confidence == .medium && !$0.defaultSelected })
        XCTAssertFalse(items.contains { $0.path.hasSuffix("Drive") })
    }
}
