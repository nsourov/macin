import XCTest
@testable import FootprintCore

final class HistoryTests: XCTestCase {
    private func store() throws -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-db-\(UUID().uuidString)")
        return (HistoryStore(url: dir.appendingPathComponent("history.sqlite")), dir)
    }

    private func fakeScan(rootPath: String, size: Int64, volume: String = "vol-1", hash: String = "h1", date: Date = Date()) -> ScanResult {
        let root = FileNode(url: URL(fileURLWithPath: rootPath), kind: .directory, modified: nil)
        let child = FileNode(url: URL(fileURLWithPath: rootPath + "/big"), kind: .directory, modified: nil)
        child.allocatedSize = size
        child.logicalSize = size
        root.children = [child]
        root.allocatedSize = size
        root.logicalSize = size
        return ScanResult(
            id: UUID(), startedAt: date, finishedAt: date, status: .completed, roots: [root],
            coverage: ScanCoverage(roots: [RootCoverage(path: rootPath, state: .scanned)]),
            volume: VolumeInfo(identifier: volume, name: "Test", totalBytes: 1_000_000_000_000, availableBytes: 500_000_000_000, availableImportantBytes: 500_000_000_000),
            categoryTotals: [.developerArtifacts: size], scannedItemCount: 2, rootSetHash: hash
        )
    }

    func testSaveLoadAndCompare() async throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.save(fakeScan(rootPath: "/r", size: 100_000_000, date: Date().addingTimeInterval(-100)), candidates: [])
        try await store.save(fakeScan(rootPath: "/r", size: 300_000_000), candidates: [makeCandidate(path: "/r/big")])

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions.count, 2)
        let cmp = try await store.compare(current: sessions[0], previous: sessions[1])
        XCTAssertTrue(cmp.isComparable)
        XCTAssertEqual(cmp.categoryDeltas.first { $0.category == .developerArtifacts }?.delta, 200_000_000)
        XCTAssertEqual(cmp.directoryDeltas.first?.path, "/r/big")
    }

    func testIncomparableScansAreFlagged() async throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(fakeScan(rootPath: "/r", size: 1, hash: "a", date: Date().addingTimeInterval(-10)), candidates: [])
        try await store.save(fakeScan(rootPath: "/r", size: 1, volume: "vol-2", hash: "b"), candidates: [])
        let s = try await store.sessions()
        let cmp = try await store.compare(current: s[0], previous: s[1])
        XCTAssertFalse(cmp.isComparable)
        XCTAssertGreaterThanOrEqual(cmp.caveats.count, 2)
    }

    func testDeleteAllAndPrune() async throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.save(fakeScan(rootPath: "/r", size: 1, date: Date().addingTimeInterval(-86_400 * 200)), candidates: [])
        try await store.save(fakeScan(rootPath: "/r", size: 1), candidates: [])
        try await store.prune(olderThanDays: 90)
        var count = try await store.sessions().count
        XCTAssertEqual(count, 1)
        try await store.deleteAll()
        count = try await store.sessions().count
        XCTAssertEqual(count, 0)
    }

    func testCorruptDatabaseIsRecovered() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.sqlite")
        try Data("this is not a database at all, just junk bytes".utf8).write(to: url)

        let store = HistoryStore(url: url)
        let sessions = try await store.sessions()
        XCTAssertTrue(sessions.isEmpty)
        let note = await store.recoveryNote
        XCTAssertNotNil(note)
    }
}
