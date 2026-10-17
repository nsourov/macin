import Foundation
import os

public struct ScanSessionSummary: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let volumeID: String
    public let volumeName: String
    public let rootSetHash: String
    public let roots: [String]
    public let status: ScanStatus
    public let scannedItemCount: Int
    public let skippedItemCount: Int
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let scannedAllocated: Int64
    public let coverageText: String
}

public struct CategoryDelta: Identifiable, Sendable {
    public var id: StorageCategory { category }
    public let category: StorageCategory
    public let previous: Int64
    public let current: Int64
    public var delta: Int64 { current - previous }
}

public struct DirectoryDelta: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let previous: Int64?
    public let current: Int64?
    public var delta: Int64 { (current ?? 0) - (previous ?? 0) }
}

public struct ScanComparison: Sendable {
    public let current: ScanSessionSummary
    public let previous: ScanSessionSummary
    public let isComparable: Bool
    public let caveats: [String]
    public let categoryDeltas: [CategoryDelta]
    public let directoryDeltas: [DirectoryDelta]
    public var availableDelta: Int64 { current.availableBytes - previous.availableBytes }
}

public struct CleanupRunSummary: Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let goalBytes: Int64?
    public let movedCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let estimatedBytes: Int64
    public let measuredChange: Int64?
}

public actor HistoryStore {
    private static let logger = Logger(subsystem: "com.macfootprint.app", category: "history")
    private static let schemaVersion: Int64 = 1

    private var connection: SQLiteConnection?
    public nonisolated let databaseURL: URL
    public private(set) var recoveryNote: String?

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacFootprint", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    public init(url: URL = HistoryStore.defaultURL) {
        databaseURL = url
    }

    private func db() throws -> SQLiteConnection {
        if let connection { return connection }
        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let conn = try SQLiteConnection(path: databaseURL.path)
            try migrate(conn)
            connection = conn
        } catch {
            Self.logger.error("History database unusable, starting fresh")
            let aside = databaseURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: databaseURL, to: aside)
            let conn = try SQLiteConnection(path: databaseURL.path)
            try migrate(conn)
            connection = conn
            recoveryNote = "The history database could not be read, so a fresh one was created. The old file was kept next to it."
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        return connection!
    }

    private func migrate(_ conn: SQLiteConnection) throws {
        let version = try conn.query("PRAGMA user_version").first?.first?.int ?? 0
        if version > Self.schemaVersion {
            throw SQLiteError(message: "History was created by a newer version of the app")
        }
        if version < 1 {
            try conn.transaction {
                try conn.execute("""
                CREATE TABLE IF NOT EXISTS scan_sessions (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    volume_id TEXT NOT NULL,
                    volume_name TEXT NOT NULL,
                    root_set_hash TEXT NOT NULL,
                    roots_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    scanned_item_count INTEGER NOT NULL,
                    skipped_item_count INTEGER NOT NULL,
                    coverage_json TEXT NOT NULL,
                    total_bytes INTEGER NOT NULL,
                    available_bytes INTEGER NOT NULL,
                    scanned_allocated INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS scan_category_totals (
                    session_id TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
                    category TEXT NOT NULL,
                    bytes INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS scan_dir_aggregates (
                    session_id TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    depth INTEGER NOT NULL,
                    allocated INTEGER NOT NULL,
                    logical INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_dir_session ON scan_dir_aggregates(session_id);
                CREATE TABLE IF NOT EXISTS cleanup_candidates (
                    session_id TEXT NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
                    detector_id TEXT NOT NULL,
                    detector_version INTEGER NOT NULL,
                    path TEXT NOT NULL,
                    classification TEXT NOT NULL,
                    confidence TEXT NOT NULL,
                    risk TEXT NOT NULL,
                    eligibility TEXT NOT NULL,
                    estimated_bytes INTEGER NOT NULL,
                    estimation_method TEXT NOT NULL,
                    action_type TEXT NOT NULL,
                    reversibility TEXT NOT NULL,
                    reason TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS cleanup_runs (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    goal_bytes INTEGER,
                    available_before INTEGER,
                    available_after INTEGER
                );
                CREATE TABLE IF NOT EXISTS cleanup_actions (
                    run_id TEXT NOT NULL REFERENCES cleanup_runs(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    detector_id TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    message TEXT NOT NULL,
                    trash_path TEXT,
                    estimated_bytes INTEGER NOT NULL
                );
                PRAGMA user_version = 1;
                """)
            }
        }
    }

    public func save(_ scan: ScanResult, candidates: [CleanupCandidate]) throws {
        let conn = try db()
        let id = scan.id.uuidString
        let coverageJSON = String(data: (try? JSONEncoder().encode(scan.coverage)) ?? Data(), encoding: .utf8) ?? "{}"
        let rootsJSON = String(data: (try? JSONEncoder().encode(scan.roots.map(\.path))) ?? Data(), encoding: .utf8) ?? "[]"
        let aggregates = Self.directoryAggregates(scan.roots)

        try conn.transaction {
            try conn.run("""
            INSERT INTO scan_sessions VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(id), .double(scan.startedAt.timeIntervalSince1970), .double(scan.finishedAt.timeIntervalSince1970),
                .text(scan.volume?.identifier ?? "unknown"), .text(scan.volume?.name ?? "Unknown"),
                .text(scan.rootSetHash), .text(rootsJSON), .text(scan.status.rawValue),
                .int(Int64(scan.scannedItemCount)), .int(Int64(scan.coverage.skippedCount)), .text(coverageJSON),
                .int(scan.volume?.totalBytes ?? 0), .int(scan.volume?.availableImportantBytes ?? 0), .int(scan.totalAllocated)
            ])
            for (category, bytes) in scan.categoryTotals {
                try conn.run("INSERT INTO scan_category_totals VALUES (?,?,?)", [.text(id), .text(category.rawValue), .int(bytes)])
            }
            for agg in aggregates {
                try conn.run("INSERT INTO scan_dir_aggregates VALUES (?,?,?,?,?)", [.text(id), .text(agg.path), .int(Int64(agg.depth)), .int(agg.allocated), .int(agg.logical)])
            }
            for c in candidates {
                try conn.run("INSERT INTO cleanup_candidates VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(id), .text(c.detectorID), .int(Int64(c.detectorVersion)), .text(c.path),
                    .text(c.classification.rawValue), .text(c.confidence.rawValue), .text(c.riskLevel.rawValue),
                    .text(c.eligibility.rawValue), .int(c.estimatedReclaimableBytes),
                    .text(c.allocatedSizeBytes > 0 ? "allocated-size" : "logical-size"),
                    .text(c.actionType.rawValue), .text(c.reversibility.rawValue), .text(c.reason)
                ])
            }
        }
    }

    static func directoryAggregates(_ roots: [FileNode], maxDepth: Int = 4, minBytes: Int64 = 50_000_000, limit: Int = 3000) -> [(path: String, depth: Int, allocated: Int64, logical: Int64)] {
        var rows: [(path: String, depth: Int, allocated: Int64, logical: Int64)] = []
        func walk(_ node: FileNode, depth: Int) {
            guard node.isContainer, node.allocatedSize >= minBytes || depth == 0 else { return }
            rows.append((node.path, depth, node.allocatedSize, node.logicalSize))
            guard depth < maxDepth else { return }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        return Array(rows.sorted { $0.allocated > $1.allocated }.prefix(limit))
    }

    public func sessions(limit: Int = 200) throws -> [ScanSessionSummary] {
        let conn = try db()
        let rows = try conn.query("""
        SELECT id, started_at, finished_at, volume_id, volume_name, root_set_hash, roots_json, status,
               scanned_item_count, skipped_item_count, coverage_json, total_bytes, available_bytes, scanned_allocated
        FROM scan_sessions ORDER BY started_at DESC LIMIT ?
        """, [.int(Int64(limit))])
        return rows.compactMap { r in
            guard let id = UUID(uuidString: r[0].text) else { return nil }
            let roots = (try? JSONDecoder().decode([String].self, from: Data(r[6].text.utf8))) ?? []
            let coverage = try? JSONDecoder().decode(ScanCoverage.self, from: Data(r[10].text.utf8))
            return ScanSessionSummary(
                id: id,
                startedAt: Date(timeIntervalSince1970: r[1].double),
                finishedAt: Date(timeIntervalSince1970: r[2].double),
                volumeID: r[3].text,
                volumeName: r[4].text,
                rootSetHash: r[5].text,
                roots: roots,
                status: ScanStatus(rawValue: r[7].text) ?? .partial,
                scannedItemCount: Int(r[8].int),
                skippedItemCount: Int(r[9].int),
                totalBytes: r[11].int,
                availableBytes: r[12].int,
                scannedAllocated: r[13].int,
                coverageText: coverage?.summaryText ?? "Unknown coverage"
            )
        }
    }

    public func categoryTotals(_ sessionID: UUID) throws -> [StorageCategory: Int64] {
        let rows = try db().query("SELECT category, bytes FROM scan_category_totals WHERE session_id = ?", [.text(sessionID.uuidString)])
        var result: [StorageCategory: Int64] = [:]
        for r in rows {
            if let c = StorageCategory(rawValue: r[0].text) { result[c] = r[1].int }
        }
        return result
    }

    public func directoryTotals(_ sessionID: UUID) throws -> [String: Int64] {
        let rows = try db().query("SELECT path, allocated FROM scan_dir_aggregates WHERE session_id = ?", [.text(sessionID.uuidString)])
        var result: [String: Int64] = [:]
        for r in rows { result[r[0].text] = r[1].int }
        return result
    }

    public func compare(current: ScanSessionSummary, previous: ScanSessionSummary) throws -> ScanComparison {
        var caveats: [String] = []
        var comparable = true
        if current.volumeID != previous.volumeID {
            comparable = false
            caveats.append("The scans are from different volumes.")
        }
        if current.rootSetHash != previous.rootSetHash {
            comparable = false
            caveats.append("The scanned locations are different, so totals are not directly comparable.")
        }
        if current.status != .completed || previous.status != .completed {
            caveats.append("At least one scan was partial or cancelled; some changes may come from coverage differences.")
        }
        if abs(current.skippedItemCount - previous.skippedItemCount) > 50 {
            caveats.append("The number of skipped items changed a lot (permissions may have changed).")
        }
        caveats.append("Folder sizes can change for reasons other than new files, such as rebuilt caches or APFS accounting.")

        let cur = try categoryTotals(current.id)
        let prev = try categoryTotals(previous.id)
        let categoryDeltas = StorageCategory.allCases.map {
            CategoryDelta(category: $0, previous: prev[$0] ?? 0, current: cur[$0] ?? 0)
        }

        let curDirs = try directoryTotals(current.id)
        let prevDirs = try directoryTotals(previous.id)
        var dirDeltas: [DirectoryDelta] = []
        for path in Set(curDirs.keys).union(prevDirs.keys) {
            let delta = DirectoryDelta(path: path, previous: prevDirs[path], current: curDirs[path])
            if delta.previous != nil && delta.current != nil && delta.delta != 0 {
                dirDeltas.append(delta)
            }
        }
        dirDeltas = Self.leafMostDeltas(dirDeltas).sorted { abs($0.delta) > abs($1.delta) }

        return ScanComparison(
            current: current,
            previous: previous,
            isComparable: comparable,
            caveats: caveats,
            categoryDeltas: categoryDeltas,
            directoryDeltas: Array(dirDeltas.prefix(50))
        )
    }

    static func leafMostDeltas(_ deltas: [DirectoryDelta]) -> [DirectoryDelta] {
        deltas.filter { parent in
            !deltas.contains { child in
                PathTools.isDescendant(child.path, of: parent.path) && abs(child.delta) * 10 >= abs(parent.delta) * 8
            }
        }
    }

    public func saveCleanup(_ run: CleanupRunResult) throws {
        let conn = try db()
        try conn.transaction {
            try conn.run("INSERT INTO cleanup_runs VALUES (?,?,?,?,?,?)", [
                .text(run.id.uuidString), .double(run.startedAt.timeIntervalSince1970), .double(run.finishedAt.timeIntervalSince1970),
                run.goalBytes.map { .int($0) } ?? .null,
                run.availableBefore.map { .int($0) } ?? .null,
                run.availableAfter.map { .int($0) } ?? .null
            ])
            for item in run.items {
                try conn.run("INSERT INTO cleanup_actions VALUES (?,?,?,?,?,?,?)", [
                    .text(run.id.uuidString), .text(item.candidate.path), .text(item.candidate.detectorID),
                    .text(item.outcome.rawValue), .text(item.message),
                    item.trashURL.map { .text($0.path) } ?? .null,
                    .int(item.candidate.estimatedReclaimableBytes)
                ])
            }
        }
    }

    public func cleanupRuns(limit: Int = 50) throws -> [CleanupRunSummary] {
        let rows = try db().query("""
        SELECT r.id, r.started_at, r.goal_bytes, r.available_before, r.available_after,
            SUM(CASE WHEN a.outcome IN ('movedToTrash', 'deleted') THEN 1 ELSE 0 END),
            SUM(CASE WHEN a.outcome = 'failed' THEN 1 ELSE 0 END),
            SUM(CASE WHEN a.outcome = 'skipped' THEN 1 ELSE 0 END),
            SUM(CASE WHEN a.outcome IN ('movedToTrash', 'deleted') THEN a.estimated_bytes ELSE 0 END)
        FROM cleanup_runs r LEFT JOIN cleanup_actions a ON a.run_id = r.id
        GROUP BY r.id ORDER BY r.started_at DESC LIMIT ?
        """, [.int(Int64(limit))])
        return rows.compactMap { r in
            guard let id = UUID(uuidString: r[0].text) else { return nil }
            let before = r[3].optionalInt
            let after = r[4].optionalInt
            return CleanupRunSummary(
                id: id,
                startedAt: Date(timeIntervalSince1970: r[1].double),
                goalBytes: r[2].optionalInt,
                movedCount: Int(r[5].int),
                failedCount: Int(r[6].int),
                skippedCount: Int(r[7].int),
                estimatedBytes: r[8].int,
                measuredChange: (before != nil && after != nil) ? after! - before! : nil
            )
        }
    }

    public func prune(olderThanDays days: Int) throws {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let conn = try db()
        try conn.transaction {
            try conn.run("DELETE FROM scan_sessions WHERE started_at < ?", [.double(cutoff)])
            try conn.run("DELETE FROM cleanup_runs WHERE started_at < ?", [.double(cutoff)])
        }
    }

    public func deleteAll() throws {
        let conn = try db()
        try conn.transaction {
            try conn.run("DELETE FROM cleanup_actions")
            try conn.run("DELETE FROM cleanup_runs")
            try conn.run("DELETE FROM cleanup_candidates")
            try conn.run("DELETE FROM scan_dir_aggregates")
            try conn.run("DELETE FROM scan_category_totals")
            try conn.run("DELETE FROM scan_sessions")
        }
        try conn.execute("VACUUM")
    }

    public func resetDatabaseFile() throws {
        connection = nil
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }
    }
}
