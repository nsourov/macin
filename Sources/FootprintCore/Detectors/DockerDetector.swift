import Foundation

public struct DockerUsageRow: Sendable, Hashable, Codable {
    public let type: String
    public let totalCount: String
    public let active: String
    public let sizeBytes: Int64
    public let reclaimableBytes: Int64
    public let sizeText: String
    public let reclaimableText: String
}

public enum DockerStatus: Sendable, Equatable {
    case notInstalled
    case daemonNotRunning
    case unavailable(String)
    case available(executable: String, rows: [DockerUsageRow])

    public var description: String {
        switch self {
        case .notInstalled: return "Docker CLI not found"
        case .daemonNotRunning: return "Docker is installed but not running"
        case .unavailable(let message): return "Docker info unavailable: \(message)"
        case .available: return "Docker usage read successfully"
        }
    }
}

public struct DockerInspector: Sendable {
    public static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "\(PathTools.home.path)/.orbstack/bin/docker",
        "\(PathTools.home.path)/.docker/bin/docker"
    ]

    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func findExecutable() -> String? {
        let fm = FileManager.default
        for path in Self.candidatePaths {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if fm.isExecutableFile(atPath: resolved) { return path }
        }
        return nil
    }

    public func inspect() -> DockerStatus {
        guard let executable = findExecutable() else { return .notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["system", "df", "--format", "{{json .}}"]
        var env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        env["PATH"] = [dir, "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return .unavailable("could not start the Docker CLI")
        }

        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return .unavailable("the Docker CLI did not respond in time")
        }

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            if stderr.localizedCaseInsensitiveContains("daemon") || stderr.localizedCaseInsensitiveContains("connect") {
                return .daemonNotRunning
            }
            return .unavailable("the Docker CLI returned an error")
        }
        return .available(executable: executable, rows: Self.parse(stdout))
    }

    public static func parse(_ output: String) -> [DockerUsageRow] {
        output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let size = obj["Size"] as? String ?? "0B"
            let reclaim = obj["Reclaimable"] as? String ?? "0B"
            return DockerUsageRow(
                type: obj["Type"] as? String ?? "Unknown",
                totalCount: "\(obj["TotalCount"] ?? "")",
                active: "\(obj["Active"] ?? "")",
                sizeBytes: parseSize(size),
                reclaimableBytes: parseSize(reclaim),
                sizeText: size,
                reclaimableText: reclaim
            )
        }
    }

    public static func parseSize(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where token.hasSuffix(suffix) {
            let number = Double(token.dropLast(suffix.count)) ?? 0
            return Int64(number * multiplier)
        }
        return 0
    }
}

public struct DockerUsageDetector: CandidateDetector {
    public let id = "docker.usage"
    public let version = 1
    public let name = "Docker usage (read-only)"
    public let inspector: DockerInspector

    public init(inspector: DockerInspector = DockerInspector()) {
        self.inspector = inspector
    }

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        guard case .available(_, let rows) = inspector.inspect() else { return [] }
        return candidates(from: rows)
    }

    public func candidates(from rows: [DockerUsageRow]) -> [CleanupCandidate] {
        rows.filter { $0.sizeBytes > 0 }.map { row in
            CleanupCandidate(
                detectorID: id,
                detectorVersion: version,
                url: URL(string: "docker://\(row.type.lowercased().replacingOccurrences(of: " ", with: "-"))")!,
                title: "Docker \(row.type)",
                itemKind: .externalResource,
                logicalSizeBytes: row.sizeBytes,
                allocatedSizeBytes: row.sizeBytes,
                classification: .containerResource,
                source: .containers,
                confidence: .medium,
                confidenceReasons: ["Reported by `docker system df`", "\(row.totalCount) total, \(row.active) active"],
                eligibility: .informationalOnly,
                riskLevel: row.type.lowercased().contains("volume") ? .high : .medium,
                riskEvidence: row.type.lowercased().contains("volume")
                    ? ["Volumes can hold databases and other data that exists nowhere else"]
                    : ["Docker reports \(row.reclaimableText) as reclaimable; that is Docker's own estimate"],
                reason: "Storage managed by Docker. Macin only reads this; it never prunes Docker data.",
                consequences: ["Review and remove items in Docker Desktop or with targeted docker commands you choose"],
                actionType: .adapterHandoff,
                reversibility: .none,
                lastModified: nil,
                identity: nil,
                handoffHint: "Open Docker Desktop → Images / Volumes / Builds to review what to remove."
            )
        }
    }
}
