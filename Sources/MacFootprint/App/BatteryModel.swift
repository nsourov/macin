import AppKit
import FootprintCore
import IOKit.ps
import SwiftUI
import UniformTypeIdentifiers

enum BatteryRange: String, CaseIterable, Identifiable {
    case day = "24 hours"
    case week = "7 days"
    case month = "30 days"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

@MainActor
final class BatteryModel: ObservableObject {
    static let hasBattery = BatteryProvider.current().hasBattery

    @Published private(set) var snapshot = BatteryProvider.current()
    @Published private(set) var samples: [BatterySample] = []
    @Published private(set) var finding: DrainFinding?
    @Published private(set) var lastRefresh = Date()

    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "battery.history") } }
    @Published var lowAlertEnabled: Bool {
        didSet {
            defaults.set(lowAlertEnabled, forKey: "battery.lowAlert")
            if lowAlertEnabled { Notifier.requestPermission() }
        }
    }
    @Published var lowThreshold: Int {
        didSet {
            defaults.set(lowThreshold, forKey: "battery.lowThreshold")
            lowAlert.threshold = lowThreshold
        }
    }
    @Published var drainAlertEnabled: Bool {
        didSet {
            defaults.set(drainAlertEnabled, forKey: "battery.drainAlert")
            if drainAlertEnabled { Notifier.requestPermission() }
        }
    }
    private let defaults = UserDefaults.standard

    private let store: MetricsStore
    private weak var monitor: SystemMonitor?
    private var lowAlert: LowBatteryAlert
    private var lastDrainAlert: Date?
    private var loop: Task<Void, Never>?
    private var fastLoop: Task<Void, Never>?
    private var watchers = 0
    private var runLoopSource: CFRunLoopSource?
    private var lastSource: PowerSourceKind?

    init(store: MetricsStore, monitor: SystemMonitor) {
        self.store = store
        self.monitor = monitor
        let d = UserDefaults.standard
        let threshold = d.object(forKey: "battery.lowThreshold") as? Int ?? 20
        historyEnabled = d.object(forKey: "battery.history") as? Bool ?? true
        lowAlertEnabled = d.bool(forKey: "battery.lowAlert")
        lowThreshold = threshold
        drainAlertEnabled = d.bool(forKey: "battery.drainAlert")
        lowAlert = LowBatteryAlert(threshold: threshold)
    }

    func start() {
        guard Self.hasBattery, loop == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let model = Unmanaged<BatteryModel>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in model.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        loop = Task { [weak self] in
            await self?.loadHistory()
            while !Task.isCancelled {
                await self?.tick(record: true)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func watch() {
        watchers += 1
        guard fastLoop == nil else { return }
        fastLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.tick(record: false)
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        fastLoop?.cancel()
        fastLoop = nil
    }

    private func powerChanged() {
        Task { await tick(record: false) }
    }

    private func tick(record: Bool) async {
        let snap = await Task.detached(priority: .utility) { BatteryProvider.current() }.value
        snapshot = snap
        lastRefresh = snap.timestamp
        let sourceChanged = lastSource != nil && lastSource != snap.source
        lastSource = snap.source
        guard snap.hasBattery, let percent = snap.chargePercent else { return }
        if lowAlertEnabled, lowAlert.shouldNotify(snap) {
            Notifier.post(id: "battery-low", title: "Battery is at \(percent)%",
                          body: "Plug in your Mac soon. You set this alert at \(lowThreshold)%.", target: .battery)
        } else if !lowAlertEnabled {
            _ = lowAlert.shouldNotify(snap)
        }
        if (record || sourceChanged) && historyEnabled {
            let sample = BatterySample(time: snap.timestamp, percent: percent, onBattery: snap.source == .battery, charging: snap.state == .charging, cpu: monitor?.cpuUsage)
            if let last = samples.last, sample.time.timeIntervalSince(last.time) < 30, !sourceChanged { return }
            try? await store.append(sample)
            samples.append(sample)
            samples.removeAll { $0.time < Date().addingTimeInterval(-BatteryRange.month.seconds) }
            evaluate()
        }
    }

    private func evaluate() {
        let result = BatteryAnalysis.diagnose(samples)
        finding = result
        guard drainAlertEnabled, result.level == .worthReviewing, snapshot.source == .battery else { return }
        if let lastDrainAlert, Date().timeIntervalSince(lastDrainAlert) < 2 * 3600 { return }
        lastDrainAlert = Date()
        Notifier.post(id: "battery-drain", title: "Battery is going down faster than usual",
                      body: result.observation, target: .battery)
    }

    func loadHistory() async {
        try? await store.prune(olderThanDays: 30)
        samples = (try? await store.batterySamples(since: Date().addingTimeInterval(-BatteryRange.month.seconds))) ?? []
        finding = BatteryAnalysis.diagnose(samples)
    }

    func samples(in range: BatteryRange) -> [BatterySample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return samples.filter { $0.time >= cutoff }
    }

    var events: [BatteryEvent] { BatteryAnalysis.events(samples).reversed() }

    var timeOnBatteryToday: TimeInterval {
        let start = Calendar.current.startOfDay(for: Date())
        let today = samples.filter { $0.time >= start }
        return zip(today, today.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.time.timeIntervalSince(pair.0.time)
            return pair.0.onBattery && gap <= BatteryAnalysis.maxGap ? total + gap : total
        }
    }

    func deleteHistory() {
        Task {
            try? await store.deleteBatteryHistory()
            samples = []
            finding = BatteryAnalysis.diagnose([])
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Macin Battery History.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let iso = ISO8601DateFormatter()
        var lines = ["time,charge_percent,on_battery,charging,processor_busy_percent"]
        for s in samples {
            lines.append("\(iso.string(from: s.time)),\(s.percent),\(s.onBattery),\(s.charging),\(s.cpu.map { String(format: "%.1f", $0 * 100) } ?? "")")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
