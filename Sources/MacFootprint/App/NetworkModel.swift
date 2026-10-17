import AppKit
import CoreWLAN
import FootprintCore
import Network
import SwiftUI
import UniformTypeIdentifiers

struct WiFiInfo: Equatable {
    var rssi: Int?
    var noise: Int?
    var channel: Int?
    var band: String?
    var txRate: Double?

    var quality: String {
        guard let rssi else { return "Unknown" }
        if rssi >= -55 { return "Excellent" }
        if rssi >= -67 { return "Good" }
        if rssi >= -75 { return "Fair" }
        return "Weak"
    }
}

struct RatePoint: Identifiable {
    let id = UUID()
    let time: Date
    let down: Double
    let up: Double
}

enum AutoCheck: String, CaseIterable, Identifiable {
    case off, hourly, sixHours

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .hourly: return "Every hour"
        case .sixHours: return "Every 6 hours"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .hourly: return 3600
        case .sixHours: return 6 * 3600
        }
    }
}

@MainActor
final class NetworkModel: ObservableObject {
    @Published private(set) var path = NetworkPathSnapshot(status: .unknown)
    @Published private(set) var lastChange: Date?
    @Published private(set) var events: [NetworkEventRecord] = []
    @Published private(set) var results: [EndpointTestResult] = []
    @Published private(set) var live: [UUID: EndpointTestResult] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?
    @Published private(set) var finding: NetworkFinding?
    @Published private(set) var latency: LatencyStats?
    @Published private(set) var latencyRunning = false
    @Published private(set) var latencyProgress = 0
    @Published private(set) var wifi: WiFiInfo?
    @Published private(set) var rates: [RatePoint] = []

    @Published var destinations: [EndpointDefinition] { didSet { saveDestinations() } }
    @Published var consented: Bool { didSet { defaults.set(consented, forKey: "network.consent") } }
    @Published var changeAlerts: Bool {
        didSet {
            defaults.set(changeAlerts, forKey: "network.changeAlerts")
            if changeAlerts { Notifier.requestPermission() }
        }
    }
    @Published var autoCheck: AutoCheck { didSet { defaults.set(autoCheck.rawValue, forKey: "network.autoCheck") } }

    private let store: MetricsStore
    private let defaults = UserDefaults.standard
    private let monitor = NWPathMonitor()
    private var runTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var watchers = 0
    private var lastCounters: (Date, InterfaceCounters)?
    private var notifiedStatus: PathStatus?
    private var pendingAlert: Task<Void, Never>?

    init(store: MetricsStore) {
        self.store = store
        let d = UserDefaults.standard
        if let data = d.data(forKey: "network.destinations"), let saved = try? JSONDecoder().decode([EndpointDefinition].self, from: data), !saved.isEmpty {
            destinations = saved
        } else {
            destinations = EndpointDefinition.builtIns
        }
        consented = d.bool(forKey: "network.consent")
        changeAlerts = d.bool(forKey: "network.changeAlerts")
        autoCheck = d.string(forKey: "network.autoCheck").flatMap(AutoCheck.init(rawValue:)) ?? .off
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] nwPath in
            let snap = Self.snapshot(nwPath)
            Task { @MainActor in self?.apply(snap) }
        }
        monitor.start(queue: DispatchQueue(label: "macin.network.path"))
        Task {
            events = (try? await store.networkEvents(since: Date().addingTimeInterval(-7 * 86_400))) ?? []
            results = (try? await store.networkResults(since: Date().addingTimeInterval(-7 * 86_400))) ?? []
            lastRun = results.last?.startedAt
            updateFinding()
        }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, self.consented, let interval = self.autoCheck.interval else { continue }
                if Date().timeIntervalSince(self.lastRun ?? .distantPast) >= interval { self.runDiagnostics() }
            }
        }
    }

    nonisolated private static func snapshot(_ p: NWPath) -> NetworkPathSnapshot {
        let status: PathStatus
        switch p.status {
        case .satisfied: status = .available
        case .unsatisfied: status = .unavailable
        case .requiresConnection: status = .transitioning
        @unknown default: status = .unknown
        }
        var kinds: [InterfaceKind] = []
        for i in p.availableInterfaces {
            let k: InterfaceKind
            switch i.type {
            case .wifi: k = .wifi
            case .wiredEthernet: k = .ethernet
            case .cellular: k = .cellular
            case .loopback: k = .loopback
            default: k = .other
            }
            if !kinds.contains(k) && k != .loopback { kinds.append(k) }
        }
        return NetworkPathSnapshot(status: status, interfaces: kinds,
                                   supportsIPv4: p.supportsIPv4, supportsIPv6: p.supportsIPv6, supportsDNS: p.supportsDNS,
                                   isExpensive: p.isExpensive, isConstrained: p.isConstrained)
    }

    private func apply(_ snap: NetworkPathSnapshot) {
        let changed = snap.differs(from: path)
        let first = path.status == .unknown
        path = snap
        refreshWiFi()
        guard changed else { return }
        lastChange = snap.timestamp
        let record = NetworkEventRecord(time: snap.timestamp, status: snap.status, interface: snap.primary)
        events.append(record)
        Task { try? await store.append(record) }
        updateFinding()
        if first { notifiedStatus = snap.status; return }
        scheduleChangeAlert()
    }

    private func scheduleChangeAlert() {
        guard changeAlerts else { return }
        pendingAlert?.cancel()
        pendingAlert = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            let status = self.path.status
            guard status == .available || status == .unavailable, status != self.notifiedStatus else { return }
            self.notifiedStatus = status
            if status == .available {
                Notifier.post(id: "network-change", title: "Back online", body: "Connected via \(self.path.primary?.rawValue ?? "network").", target: .network)
            } else {
                Notifier.post(id: "network-change", title: "Connection lost", body: "Your Mac has no usable network right now.", target: .network)
            }
        }
    }

    func watch() {
        watchers += 1
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleRates()
                self?.refreshWiFi()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        liveTask?.cancel()
        liveTask = nil
        lastCounters = nil
    }

    private func sampleRates() {
        guard let now = InterfaceCounters.read() else { return }
        let time = Date()
        if let (t, prev) = lastCounters, let rate = InterfaceCounters.rate(from: prev, to: now, seconds: time.timeIntervalSince(t)) {
            rates.append(RatePoint(time: time, down: rate.down, up: rate.up))
            if rates.count > 60 { rates.removeFirst(rates.count - 60) }
        }
        lastCounters = (time, now)
    }

    private func refreshWiFi() {
        guard path.interfaces.contains(.wifi), let i = CWWiFiClient.shared().interface(), i.powerOn() else {
            wifi = nil
            return
        }
        let ch = i.wlanChannel()
        let band: String?
        switch ch?.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = nil
        }
        let rssi = i.rssiValue()
        let noise = i.noiseMeasurement()
        wifi = WiFiInfo(rssi: rssi == 0 ? nil : rssi, noise: noise == 0 ? nil : noise, channel: ch?.channelNumber, band: band, txRate: i.transmitRate() > 0 ? i.transmitRate() : nil)
    }

    var enabledDestinations: [EndpointDefinition] { destinations.filter(\.enabled) }

    func runDiagnostics(only: EndpointDefinition? = nil) {
        let list = only.map { [$0] } ?? enabledDestinations
        guard !isRunning, consented, !list.isEmpty else { return }
        isRunning = true
        let pathOK = path.status == .available
        live = Dictionary(uniqueKeysWithValues: list.map { d in
            (d.id, EndpointTestResult(endpointID: d.id, endpointName: d.name, host: d.host ?? d.url,
                                      stages: StageKind.allCases.map { StageResult(kind: $0, state: $0 == .path ? (pathOK ? .passed : .failed) : .running) }))
        })
        runTask = Task { [weak self] in
            var finished: [EndpointTestResult] = []
            await withTaskGroup(of: EndpointTestResult.self) { group in
                for d in list { group.addTask { await EndpointTester.run(d, pathAvailable: pathOK) } }
                for await result in group {
                    finished.append(result)
                    self?.live[result.endpointID] = result
                }
            }
            guard let self else { return }
            if Task.isCancelled {
                for d in list where !finished.contains(where: { $0.endpointID == d.id }) {
                    self.live[d.id] = EndpointTestResult(endpointID: d.id, endpointName: d.name, host: d.host ?? d.url,
                                                         stages: StageKind.allCases.map { StageResult(kind: $0, state: .skipped, detail: "Cancelled") })
                }
            }
            for r in finished { try? await self.store.append(r) }
            self.results.append(contentsOf: finished)
            self.results.removeAll { $0.startedAt < Date().addingTimeInterval(-7 * 86_400) }
            self.lastRun = Date()
            self.isRunning = false
            self.updateFinding()
        }
    }

    func cancel() {
        runTask?.cancel()
        latencyTask?.cancel()
    }

    var latestResults: [EndpointTestResult] {
        guard let lastRun else { return [] }
        return results.filter { $0.startedAt >= lastRun.addingTimeInterval(-120) }
            .reduce(into: [UUID: EndpointTestResult]()) { $0[$1.endpointID] = $1 }
            .values.sorted { $0.endpointName < $1.endpointName }
    }

    private func updateFinding() {
        finding = NetworkDiagnosis.evaluate(path: path, results: isFresh ? latestResults : [])
    }

    var isFresh: Bool { lastRun.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false }

    func measureLatency(_ endpoint: EndpointDefinition, count: Int = 5) {
        guard !latencyRunning, consented else { return }
        latencyRunning = true
        latency = nil
        latencyProgress = 0
        latencyTask = Task { [weak self] in
            var samples: [TimeInterval] = []
            var failures = 0
            for i in 0..<count {
                if Task.isCancelled { break }
                if let t = await EndpointTester.connectTime(endpoint) { samples.append(t) } else { failures += 1 }
                self?.latencyProgress = i + 1
                if i < count - 1 { try? await Task.sleep(for: .seconds(1)) }
            }
            self?.latency = LatencyStats(samples: samples, failures: failures)
            self?.latencyRunning = false
        }
    }

    func addDestination(name: String, url: String) -> String? {
        guard let valid = EndpointDefinition.validate(url) else { return "Enter a full web address starting with https://" }
        guard destinations.count < 12 else { return "You can add up to 12 test sites." }
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? (valid.host ?? "Custom") : name
        destinations.append(EndpointDefinition(name: title, url: valid.absoluteString, disclosure: "Added by you."))
        return nil
    }

    func remove(_ endpoint: EndpointDefinition) {
        destinations.removeAll { $0.id == endpoint.id }
    }

    func restoreDefaults() {
        destinations = EndpointDefinition.builtIns
    }

    private func saveDestinations() {
        if let data = try? JSONEncoder().encode(destinations) { defaults.set(data, forKey: "network.destinations") }
    }

    func deleteHistory() {
        Task {
            try? await store.deleteNetworkHistory()
            events = []
            results = []
            lastRun = nil
            updateFinding()
        }
    }

    func report(includeSystem: Bool, includeHosts: Bool) -> String {
        var lines = ["Macin network report", "Created: \(Date().formatted(date: .abbreviated, time: .standard))"]
        if includeSystem { lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)") }
        lines.append("")
        lines.append("Connection: \(path.status.rawValue)")
        lines.append("Interfaces: \(path.interfaces.map(\.rawValue).joined(separator: ", ").ifEmpty("none reported"))")
        lines.append("IPv4: \(yesNo(path.supportsIPv4))  IPv6: \(yesNo(path.supportsIPv6))  DNS: \(yesNo(path.supportsDNS))")
        lines.append("Expensive: \(yesNo(path.isExpensive))  Low Data Mode: \(yesNo(path.isConstrained))")
        if let wifi {
            lines.append("Wi-Fi signal: \(wifi.rssi.map { "\($0) dBm" } ?? "n/a"), noise: \(wifi.noise.map { "\($0) dBm" } ?? "n/a"), channel: \(wifi.channel.map(String.init) ?? "n/a") \(wifi.band ?? "")")
        }
        lines.append("")
        if let finding {
            lines.append("Summary: \(finding.title)")
            lines.append(finding.detail)
            lines.append("Confidence: \(finding.confidence)")
            lines.append("Next step: \(finding.nextStep)")
            lines.append("")
        }
        for r in latestResults {
            lines.append("Test site: \(r.endpointName)\(includeHosts ? " (\(r.host))" : "") at \(r.startedAt.formatted(date: .omitted, time: .standard))")
            for s in r.stages {
                lines.append("  \(s.kind.rawValue): \(s.state.rawValue)\(s.duration.map { " · \(Int($0 * 1000)) ms" } ?? "")\(s.detail.map { " · \($0)" } ?? "")")
            }
        }
        lines.append("")
        lines.append("Not included: network names, hardware and IP addresses, DNS servers, browsing activity.")
        lines.append("Limits: a test only shows how these sites answered at that moment. It does not prove every service works.")
        return lines.joined(separator: "\n")
    }

    func export(includeSystem: Bool, includeHosts: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Macin Network Report.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report(includeSystem: includeSystem, includeHosts: includeHosts).write(to: url, atomically: true, encoding: .utf8)
    }

    private func yesNo(_ v: Bool?) -> String {
        guard let v else { return "not reported" }
        return v ? "yes" : "no"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
