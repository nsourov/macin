import Foundation

public struct NetworkEventRecord: Sendable, Identifiable, Equatable {
    public var id: Date { time }
    public let time: Date
    public let status: PathStatus
    public let interface: InterfaceKind?

    public init(time: Date, status: PathStatus, interface: InterfaceKind?) {
        self.time = time
        self.status = status
        self.interface = interface
    }
}

public actor MetricsStore {
    private var connection: SQLiteConnection?
    public nonisolated let databaseURL: URL

    public static var defaultURL: URL {
        HistoryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("metrics.sqlite")
    }

    public init(url: URL = MetricsStore.defaultURL) {
        databaseURL = url
    }

    private func db() throws -> SQLiteConnection {
        if let connection { return connection }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let conn: SQLiteConnection
        do {
            conn = try SQLiteConnection(path: databaseURL.path)
            try migrate(conn)
        } catch {
            try? FileManager.default.removeItem(at: databaseURL)
            let fresh = try SQLiteConnection(path: databaseURL.path)
            try migrate(fresh)
            connection = fresh
            return fresh
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        connection = conn
        return conn
    }

    private func migrate(_ conn: SQLiteConnection) throws {
        let version = try conn.query("PRAGMA user_version").first?.first?.int ?? 0
        if version < 1 {
            try conn.transaction {
                try conn.execute("""
                CREATE TABLE IF NOT EXISTS battery_samples (
                    time REAL PRIMARY KEY,
                    percent INTEGER NOT NULL,
                    on_battery INTEGER NOT NULL,
                    charging INTEGER NOT NULL,
                    cpu REAL
                );
                CREATE TABLE IF NOT EXISTS network_events (
                    time REAL NOT NULL,
                    status TEXT NOT NULL,
                    interface TEXT
                );
                CREATE INDEX IF NOT EXISTS network_events_time ON network_events(time);
                CREATE TABLE IF NOT EXISTS network_results (
                    id TEXT PRIMARY KEY,
                    time REAL NOT NULL,
                    endpoint_id TEXT NOT NULL,
                    endpoint_name TEXT NOT NULL,
                    host TEXT NOT NULL,
                    stages_json TEXT NOT NULL,
                    http_status INTEGER,
                    bytes INTEGER
                );
                CREATE INDEX IF NOT EXISTS network_results_time ON network_results(time);
                PRAGMA user_version = 1;
                """)
            }
        }
    }

    public func append(_ sample: BatterySample) throws {
        try db().run("INSERT OR REPLACE INTO battery_samples VALUES (?, ?, ?, ?, ?)", [
            .double(sample.time.timeIntervalSince1970), .int(Int64(sample.percent)),
            .int(sample.onBattery ? 1 : 0), .int(sample.charging ? 1 : 0),
            sample.cpu.map { .double($0) } ?? .null
        ])
    }

    public func batterySamples(since: Date) throws -> [BatterySample] {
        try db().query("SELECT time, percent, on_battery, charging, cpu FROM battery_samples WHERE time >= ? ORDER BY time", [.double(since.timeIntervalSince1970)]).map {
            BatterySample(time: Date(timeIntervalSince1970: $0[0].double), percent: Int($0[1].int), onBattery: $0[2].int == 1, charging: $0[3].int == 1, cpu: $0[4].optionalInt == nil ? nil : $0[4].double)
        }
    }

    public func deleteBatteryHistory() throws {
        try db().execute("DELETE FROM battery_samples")
    }

    public func append(_ event: NetworkEventRecord) throws {
        try db().run("INSERT INTO network_events VALUES (?, ?, ?)", [
            .double(event.time.timeIntervalSince1970), .text(event.status.rawValue), event.interface.map { .text($0.rawValue) } ?? .null
        ])
    }

    public func networkEvents(since: Date) throws -> [NetworkEventRecord] {
        try db().query("SELECT time, status, interface FROM network_events WHERE time >= ? ORDER BY time", [.double(since.timeIntervalSince1970)]).map {
            NetworkEventRecord(time: Date(timeIntervalSince1970: $0[0].double), status: PathStatus(rawValue: $0[1].text) ?? .unknown, interface: $0[2].optionalInt == nil && $0[2].text.isEmpty ? nil : InterfaceKind(rawValue: $0[2].text))
        }
    }

    public func append(_ result: EndpointTestResult) throws {
        let stages = String(data: try JSONEncoder().encode(result.stages), encoding: .utf8) ?? "[]"
        try db().run("INSERT OR REPLACE INTO network_results VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
            .text(result.id.uuidString), .double(result.startedAt.timeIntervalSince1970), .text(result.endpointID.uuidString),
            .text(result.endpointName), .text(result.host), .text(stages),
            result.httpStatus.map { .int(Int64($0)) } ?? .null, result.bytes.map { .int(Int64($0)) } ?? .null
        ])
    }

    public func networkResults(since: Date) throws -> [EndpointTestResult] {
        try db().query("SELECT id, time, endpoint_id, endpoint_name, host, stages_json, http_status, bytes FROM network_results WHERE time >= ? ORDER BY time", [.double(since.timeIntervalSince1970)]).compactMap { row in
            guard let id = UUID(uuidString: row[0].text), let endpoint = UUID(uuidString: row[2].text) else { return nil }
            let stages = (try? JSONDecoder().decode([StageResult].self, from: Data(row[5].text.utf8))) ?? []
            return EndpointTestResult(id: id, endpointID: endpoint, endpointName: row[3].text, host: row[4].text, startedAt: Date(timeIntervalSince1970: row[1].double), stages: stages, httpStatus: row[6].optionalInt.map(Int.init), bytes: row[7].optionalInt.map(Int.init))
        }
    }

    public func deleteNetworkHistory() throws {
        try db().execute("DELETE FROM network_events; DELETE FROM network_results;")
    }

    public func prune(olderThanDays days: Int, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let conn = try db()
        try conn.run("DELETE FROM battery_samples WHERE time < ?", [.double(cutoff)])
        try conn.run("DELETE FROM network_events WHERE time < ?", [.double(cutoff)])
        try conn.run("DELETE FROM network_results WHERE time < ?", [.double(cutoff)])
    }
}
