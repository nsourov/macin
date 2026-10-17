import Foundation

public enum PathStatus: String, Sendable, Codable {
    case available, unavailable, transitioning, unknown
}

public enum InterfaceKind: String, Sendable, Codable, CaseIterable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case cellular = "Cellular"
    case other = "Other"
    case loopback = "Loopback"
}

public struct NetworkPathSnapshot: Sendable, Equatable {
    public var timestamp: Date
    public var status: PathStatus
    public var interfaces: [InterfaceKind]
    public var supportsIPv4: Bool?
    public var supportsIPv6: Bool?
    public var supportsDNS: Bool?
    public var isExpensive: Bool?
    public var isConstrained: Bool?

    public init(timestamp: Date = Date(), status: PathStatus, interfaces: [InterfaceKind] = [], supportsIPv4: Bool? = nil, supportsIPv6: Bool? = nil, supportsDNS: Bool? = nil, isExpensive: Bool? = nil, isConstrained: Bool? = nil) {
        self.timestamp = timestamp
        self.status = status
        self.interfaces = interfaces
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public var primary: InterfaceKind? { interfaces.first }

    public func differs(from other: NetworkPathSnapshot) -> Bool {
        status != other.status || primary != other.primary
    }
}

public struct EndpointDefinition: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var url: String
    public var expectedStatus: Int?
    public var timeout: TimeInterval
    public var maxBytes: Int
    public var enabled: Bool
    public var isBuiltIn: Bool
    public var disclosure: String

    public init(id: UUID = UUID(), name: String, url: String, expectedStatus: Int? = nil, timeout: TimeInterval = 5, maxBytes: Int = 64_000, enabled: Bool = true, isBuiltIn: Bool = false, disclosure: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.expectedStatus = expectedStatus
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
        self.disclosure = disclosure
    }

    public var host: String? { URL(string: url)?.host }

    public static let builtIns: [EndpointDefinition] = [
        EndpointDefinition(id: UUID(uuidString: "6F1D2A40-0000-4000-8000-000000000001")!, name: "Apple", url: "https://captive.apple.com/hotspot-detect.html", expectedStatus: 200, isBuiltIn: true,
                           disclosure: "Apple's own connection check page. Macin sends a normal web request with no personal data."),
        EndpointDefinition(id: UUID(uuidString: "6F1D2A40-0000-4000-8000-000000000002")!, name: "Cloudflare", url: "https://1.1.1.1/cdn-cgi/trace", expectedStatus: 200, isBuiltIn: true,
                           disclosure: "Cloudflare's public test page. Macin sends a normal web request with no personal data."),
        EndpointDefinition(id: UUID(uuidString: "6F1D2A40-0000-4000-8000-000000000003")!, name: "Google", url: "https://www.google.com/generate_204", expectedStatus: 204, isBuiltIn: true,
                           disclosure: "Google's tiny connection check page. Macin sends a normal web request with no personal data.")
    ]

    public static func validate(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

public enum StageState: String, Sendable, Codable {
    case queued, running, passed, failed, timedOut, skipped, unsupported
}

public enum StageKind: String, Sendable, Codable, CaseIterable {
    case path = "Connection"
    case dns = "Name lookup (DNS)"
    case connect = "Connect"
    case tls = "Secure connection"
    case http = "Web response"
}

public struct StageResult: Sendable, Equatable, Codable {
    public var kind: StageKind
    public var state: StageState
    public var duration: TimeInterval?
    public var detail: String?

    public init(kind: StageKind, state: StageState, duration: TimeInterval? = nil, detail: String? = nil) {
        self.kind = kind
        self.state = state
        self.duration = duration
        self.detail = detail
    }
}

public struct EndpointTestResult: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var endpointID: UUID
    public var endpointName: String
    public var host: String
    public var startedAt: Date
    public var stages: [StageResult]
    public var httpStatus: Int?
    public var bytes: Int?

    public init(id: UUID = UUID(), endpointID: UUID, endpointName: String, host: String, startedAt: Date = Date(), stages: [StageResult], httpStatus: Int? = nil, bytes: Int? = nil) {
        self.id = id
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.host = host
        self.startedAt = startedAt
        self.stages = stages
        self.httpStatus = httpStatus
        self.bytes = bytes
    }

    public func stage(_ kind: StageKind) -> StageResult? { stages.first { $0.kind == kind } }
    public var firstFailure: StageResult? { stages.first { $0.state == .failed || $0.state == .timedOut } }
    public var passed: Bool { firstFailure == nil && stages.contains { $0.kind == .http && $0.state == .passed } }
    public var totalDuration: TimeInterval? {
        let values = stages.filter { $0.kind != .path }.compactMap(\.duration)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

public struct NetworkFinding: Sendable, Equatable {
    public enum Level: String, Sendable { case good, warning, problem, unknown }
    public let level: Level
    public let title: String
    public let detail: String
    public let evidence: [String]
    public let confidence: String
    public let nextStep: String
}

public enum NetworkDiagnosis {
    public static func evaluate(path: NetworkPathSnapshot, results: [EndpointTestResult]) -> NetworkFinding {
        if path.status != .available {
            return NetworkFinding(level: .problem, title: "No usable connection",
                                  detail: "macOS reports no usable network path right now.",
                                  evidence: ["Connection status: \(path.status.rawValue)"],
                                  confidence: "High — reported by macOS",
                                  nextStep: "Check that Wi-Fi is on and joined, or that the cable is plugged in. Then look in System Settings → Network.")
        }
        guard !results.isEmpty else {
            return NetworkFinding(level: .unknown, title: "Connected, not tested yet",
                                  detail: "Your Mac has a network path. That alone does not prove websites will load.",
                                  evidence: ["Connection status: available"],
                                  confidence: "Low — no tests have run",
                                  nextStep: "Run a check to test real websites.")
        }
        let passed = results.filter(\.passed)
        let failed = results.filter { !$0.passed }
        let evidence = results.map { r -> String in
            if let f = r.firstFailure { return "\(r.endpointName): failed at \(f.kind.rawValue.lowercased())\(f.detail.map { " (\($0))" } ?? "")" }
            return "\(r.endpointName): OK" + (r.totalDuration.map { " in \(Int($0 * 1000)) ms" } ?? "")
        }
        if failed.isEmpty {
            return NetworkFinding(level: .good, title: "Internet is working",
                                  detail: "All \(results.count) test sites answered.",
                                  evidence: evidence,
                                  confidence: results.count >= 2 ? "High — several sites passed" : "Medium — only one site was tested",
                                  nextStep: "Nothing to do. If one app still fails, the problem is likely with that service.")
        }
        if !passed.isEmpty {
            return NetworkFinding(level: .warning, title: "Some sites failed",
                                  detail: "\(passed.count) of \(results.count) test sites worked, so your Internet is up. The failing site may have its own problem.",
                                  evidence: evidence,
                                  confidence: "Medium — sites disagree",
                                  nextStep: "Try the failing site again later. It may be down, blocked by a VPN or firewall, or need a login.")
        }
        let failures = failed.compactMap(\.firstFailure?.kind)
        let all: (StageKind) -> Bool = { k in failures.count == failed.count && failures.allSatisfy { $0 == k } }
        if all(.dns) {
            return NetworkFinding(level: .problem, title: "Name lookup is failing",
                                  detail: "Your Mac is connected, but it can't turn website names into addresses (DNS).",
                                  evidence: evidence,
                                  confidence: failed.count >= 2 ? "Medium — every site failed at the same step" : "Low — only one site was tested",
                                  nextStep: "Turn Wi-Fi off and on, or restart your router. If you set custom DNS servers, check them in System Settings → Network.")
        }
        if all(.connect) || all(.tls) {
            return NetworkFinding(level: .problem, title: "Can't reach websites",
                                  detail: "Names resolve, but connections don't complete. A captive portal (hotel or café login), VPN, firewall or router issue may be involved.",
                                  evidence: evidence,
                                  confidence: "Medium — the exact cause can't be confirmed from here",
                                  nextStep: "Open a browser to see if a login page appears. Try turning off any VPN. Restart the router if it continues.")
        }
        if all(.http) {
            return NetworkFinding(level: .problem, title: "Sites answered unexpectedly",
                                  detail: "Connections work, but the sites did not reply as expected. A login page or filter may be in the way.",
                                  evidence: evidence,
                                  confidence: "Medium",
                                  nextStep: "Open a browser to check for a login page.")
        }
        return NetworkFinding(level: .problem, title: "Websites are not loading",
                              detail: "All test sites failed, at different steps.",
                              evidence: evidence,
                              confidence: "Low — mixed results",
                              nextStep: "Turn Wi-Fi off and on, then run the check again. Restart the router if it continues.")
    }
}

public struct LatencyStats: Sendable, Equatable {
    public let samples: [TimeInterval]
    public let failures: Int

    public init(samples: [TimeInterval], failures: Int) {
        self.samples = samples
        self.failures = failures
    }

    public var median: TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    public var minimum: TimeInterval? { samples.min() }
    public var maximum: TimeInterval? { samples.max() }
    public var jitter: TimeInterval? {
        guard samples.count > 1 else { return nil }
        let diffs = zip(samples, samples.dropFirst()).map { abs($0 - $1) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }
}
