import XCTest
@testable import FootprintCore

final class TrashEmptierTests: XCTestCase {
    func testEmptiesOnlyInsideTrashAndKeepsTrashFolder() throws {
        let tree = try TempTree()
        let trash = try tree.dir(".Trash")
        try tree.file(".Trash/movie.mov", bytes: 40_000)
        try tree.file(".Trash/old/cache.bin", bytes: 20_000)
        let outside = try tree.file("keep.txt", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("link"), withDestinationURL: outside)

        let emptier = TrashEmptier(trashURL: trash)
        XCTAssertGreaterThanOrEqual(emptier.size(), 60_000)

        let result = emptier.empty()
        XCTAssertEqual(result.removedCount, 3)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertGreaterThanOrEqual(result.removedBytes, 60_000)
        XCTAssertTrue(emptier.items().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}

final class CategoryItemsTests: XCTestCase {
    func testLargestItemsDrillsIntoCategoryFolders() async throws {
        let tree = try TempTree()
        try tree.file("Library/Caches/AppA/data.bin", bytes: 3_000_000)
        try tree.file("Library/Caches/AppB/data.bin", bytes: 2_000_000)
        try tree.file("Documents/movie.mov", bytes: 4_000_000)
        let scan = await tree.scan()

        let items = CategoryClassifier(home: tree.root).largestItems(in: .cachesSupport, roots: scan.roots)
        let names = items.map(\.node.name)
        XCTAssertTrue(names.contains("AppA"))
        XCTAssertTrue(names.contains("AppB"))
        XCTAssertFalse(names.contains("movie.mov"))
        XCTAssertFalse(names.contains("Documents"))
    }
}
