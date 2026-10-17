import XCTest
@testable import FootprintCore

private final class MoveTrash: TrashMover, @unchecked Sendable {
    let destination: URL
    var moved: [String] = []

    init(destination: URL) {
        self.destination = destination
    }

    func trash(_ url: URL) throws -> URL? {
        let target = destination.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        moved.append(url.standardizedFileURL.path)
        return target
    }
}

final class UninstallTests: XCTestCase {
    private func makeApp(_ tree: TempTree, _ relative: String, id: String) throws -> InstalledApp {
        let url = try tree.dir(relative)
        let contents = try tree.dir(relative + "/Contents")
        (["CFBundleIdentifier": id] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        try tree.file(relative + "/Contents/MacOS/bin", bytes: 10_000)
        return try XCTUnwrap(AppDiscovery.read(url, location: .userApplications))
    }

    private func setup() throws -> (TempTree, InstalledApp, MoveTrash) {
        let tree = try TempTree()
        let app = try makeApp(tree, "Applications/Alpha.app", id: "com.example.alpha")
        let trash = MoveTrash(destination: try tree.dir("TrashBin"))
        return (tree, app, trash)
    }

    func testRemovesAppAndOnlyPickedData() async throws {
        let (tree, app, trash) = try setup()
        try tree.file("Library/Caches/com.example.alpha/a", bytes: 1_000)
        try tree.file("Library/Application Support/com.example.alpha/b", bytes: 1_000)
        let related = RelatedDataScanner.scan(for: app, home: tree.root)
        let caches = try XCTUnwrap(related.first { $0.category == .caches })

        let tool = AppUninstaller(home: tree.root, trashMover: trash)
        let result = await tool.uninstall(app, appBytes: 10_000, removeApp: true, items: [caches])

        XCTAssertTrue(result.appRemoved)
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("Library/Application Support/com.example.alpha").path))
    }

    func testRunningAppIsNotTouched() async throws {
        let (tree, app, trash) = try setup()
        try tree.file("Library/Caches/com.example.alpha/a", bytes: 1_000)
        let related = RelatedDataScanner.scan(for: app, home: tree.root)

        let tool = AppUninstaller(home: tree.root, trashMover: trash) { _ in true }
        let result = await tool.uninstall(app, appBytes: 0, removeApp: true, items: related)

        XCTAssertFalse(result.appRemoved)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(trash.moved.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testBlocksSystemAppsAndAppsOutsideAppFolders() throws {
        let (tree, _, trash) = try setup()
        let tool = AppUninstaller(home: tree.root, trashMover: trash)
        let system = InstalledApp(path: "/System/Applications/Calculator.app", name: "Calculator", bundleID: "com.apple.calculator", version: nil, location: .system, modified: nil)
        XCTAssertNotNil(tool.blockReason(for: system))

        let elsewhere = try makeApp(tree, "Downloads/Beta.app", id: "com.example.beta")
        XCTAssertNotNil(tool.blockReason(for: elsewhere))
    }

    func testBlocksWhenBundleChanged() throws {
        let (tree, app, trash) = try setup()
        let swapped = InstalledApp(path: app.path, name: app.name, bundleID: "com.other.app", version: nil, location: app.location, modified: nil)
        XCTAssertNotNil(AppUninstaller(home: tree.root, trashMover: trash).blockReason(for: swapped))
    }

    func testRelatedItemOutsideLibraryIsSkipped() async throws {
        let (tree, app, trash) = try setup()
        let outside = try tree.file("Documents/keep.txt", bytes: 100)
        let fake = RelatedItem(path: outside.path, category: .support, bytes: 100, confidence: .high, risk: .persistent, evidence: "", defaultSelected: true)

        let result = await AppUninstaller(home: tree.root, trashMover: trash).uninstall(app, appBytes: 0, removeApp: true, items: [fake])

        XCTAssertTrue(result.appRemoved)
        XCTAssertEqual(result.problems.map(\.path), [outside.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
