import AppKit
import FootprintCore
import SwiftUI

enum MemoryGroupKind: String {
    case app = "App"
    case backgroundApp = "Background app"
    case process = "Background process"
}

struct MemoryGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let appPath: String?
    let kind: MemoryGroupKind
    let footprintBytes: Int64
    let processes: [ProcessMemorySample]
    let trend: MemoryTrend
    let recent: [MemoryHistory.Point]
    let cpu: Double?
    let cpuRecent: [PerformancePoint]
    var power: Double? = nil
    var energyJoules: Double = 0
    var powerRecent: [PerformancePoint] = []
}

struct MemoryProcessRow: Identifiable, Equatable {
    var id: ProcessIdentity { sample.identity }
    let sample: ProcessMemorySample
    let trend: MemoryTrend
    let cpu: Double?
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot: SystemMemorySnapshot?
    @Published private(set) var groups: [MemoryGroup] = []
    @Published private(set) var processes: [MemoryProcessRow] = []
    @Published private(set) var coverage: ProcessCoverage?
    @Published private(set) var history = MemoryHistory(window: 300)
    @Published private(set) var pressure: MemoryPressureState = .unknown
    @Published private(set) var pressureSince: Date?
    @Published private(set) var cpuUsage: Double?
    @Published private(set) var cpuHistory: [PerformancePoint] = []
    @Published private(set) var thermal: ThermalLevel = .unknown
    @Published private(set) var temperature = TemperatureReading()
    @Published private(set) var chipTempHistory: [PerformancePoint] = []
    @Published private(set) var lowPowerMode = false
    @Published private(set) var observations: [PerformanceObservation] = []
    @Published private var dismissed: Set<String> = []

    var visibleObservations: [PerformanceObservation] { observations.filter { !dismissed.contains($0.id) } }

    func dismiss(_ observation: PerformanceObservation) {
        dismissed.insert(observation.id)
    }

    private let systemProvider: SystemMemoryProviding = SystemMemoryProvider()
    private let processProvider: ProcessMemoryProviding = ProcessMemoryProvider()
    private let pressureMonitor = MemoryPressureMonitor()
    private let temperatureSensors = TemperatureSensors()
    private var groupHistory: [String: [MemoryHistory.Point]] = [:]
    private var groupCPUHistory: [String: [PerformancePoint]] = [:]
    private var lastTicks: CPUTicks?
    private var lastCPUTime: [ProcessIdentity: (Date, UInt64)] = [:]
    private var lastEnergy: [ProcessIdentity: (Date, UInt64)] = [:]
    private var groupPowerHistory: [String: [PerformancePoint]] = [:]
    private let rules = PerformanceRules()
    private var loop: Task<Void, Never>?
    private var watchers = 0

    var interval: Duration { watchers > 1 ? .seconds(2) : .seconds(5) }

    func start() {
        watchers += 1
        guard loop == nil else { return }
        pressureMonitor.start { [weak self] state, time in
            Task { @MainActor in self?.setPressure(state, at: time) }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                try? await Task.sleep(for: self?.interval ?? .seconds(2))
            }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        loop?.cancel()
        loop = nil
        pressureMonitor.stop()
    }

    private func setPressure(_ state: MemoryPressureState, at time: Date) {
        guard state != pressure else { return }
        pressure = state
        pressureSince = time
    }

    private func sampleOnce() async {
        let pressure = pressureMonitor.current
        let system = systemProvider
        let process = processProvider
        let sensors = temperatureSensors
        let result = await Task.detached(priority: .utility) {
            (system.snapshot(pressure: pressure), process.samples(), SystemCPU.ticks(), sensors.read())
        }.value
        guard !Task.isCancelled else { return }
        applyTemperature(result.3, at: result.0.timestamp)
        applyCPU(ticks: result.2, at: result.0.timestamp)
        apply(snapshot: result.0, samples: result.1.samples, coverage: result.1.coverage)
    }

    private func applyTemperature(_ reading: TemperatureReading, at time: Date) {
        temperature = reading
        guard let chip = reading.chip else { return }
        chipTempHistory.append(PerformancePoint(time: time, value: chip))
        let cutoff = time.addingTimeInterval(-history.window)
        chipTempHistory.removeAll { $0.time < cutoff }
    }

    private func applyCPU(ticks: CPUTicks?, at time: Date) {
        thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let ticks, let last = lastTicks, let usage = SystemCPU.usage(from: last, to: ticks) {
            cpuUsage = usage
            cpuHistory.append(PerformancePoint(time: time, value: usage))
            let cutoff = time.addingTimeInterval(-history.window)
            cpuHistory.removeAll { $0.time < cutoff }
        }
        lastTicks = ticks
    }

    private func apply(snapshot: SystemMemorySnapshot, samples: [ProcessMemorySample], coverage: ProcessCoverage) {
        if self.pressure != snapshot.pressure, snapshot.pressure != .unknown { setPressure(snapshot.pressure, at: snapshot.timestamp) }
        history.record(snapshot, samples: samples)
        self.snapshot = snapshot
        self.coverage = coverage

        var cpuByProcess: [ProcessIdentity: Double] = [:]
        var nextCPUTime: [ProcessIdentity: (Date, UInt64)] = [:]
        for sample in samples {
            if let prev = lastCPUTime[sample.identity],
               let usage = SystemCPU.processUsage(fromNanos: prev.1, at: prev.0, toNanos: sample.cpuTimeNanos, at: sample.timestamp) {
                cpuByProcess[sample.identity] = usage
            }
            nextCPUTime[sample.identity] = (sample.timestamp, sample.cpuTimeNanos)
        }
        lastCPUTime = nextCPUTime

        var powerByProcess: [ProcessIdentity: Double] = [:]
        var nextEnergy: [ProcessIdentity: (Date, UInt64)] = [:]
        for sample in samples where sample.energyNanojoules > 0 {
            if let prev = lastEnergy[sample.identity], sample.energyNanojoules >= prev.1 {
                let seconds = sample.timestamp.timeIntervalSince(prev.0)
                if seconds > 0.5 { powerByProcess[sample.identity] = Double(sample.energyNanojoules - prev.1) / 1e9 / seconds }
            }
            nextEnergy[sample.identity] = (sample.timestamp, sample.energyNanojoules)
        }
        lastEnergy = nextEnergy

        processes = samples
            .map { MemoryProcessRow(sample: $0, trend: MemoryHistory.trend(history.points(for: $0.identity)), cpu: cpuByProcess[$0.identity]) }
            .sorted { $0.sample.footprintBytes > $1.sample.footprintBytes }

        let regularApps = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.standardizedFileURL.path })

        var buckets: [String: [ProcessMemorySample]] = [:]
        var appPaths: [String: String] = [:]
        for sample in samples {
            if let app = AppBundleResolver.owningAppPath(for: sample.executablePath) {
                buckets[app, default: []].append(sample)
                appPaths[app] = app
            } else {
                buckets["proc:" + sample.name, default: []].append(sample)
            }
        }

        let cutoff = snapshot.timestamp.addingTimeInterval(-history.window)
        var built: [MemoryGroup] = []
        for (key, items) in buckets {
            let total = items.reduce(0) { $0 + $1.footprintBytes }
            groupHistory[key, default: []].append(MemoryHistory.Point(time: snapshot.timestamp, bytes: total))
            groupHistory[key]?.removeAll { $0.time < cutoff }
            let cpuValues = items.compactMap { cpuByProcess[$0.identity] }
            let groupCPU: Double? = cpuValues.isEmpty ? nil : cpuValues.reduce(0, +)
            if let groupCPU {
                groupCPUHistory[key, default: []].append(PerformancePoint(time: snapshot.timestamp, value: groupCPU))
                groupCPUHistory[key]?.removeAll { $0.time < cutoff }
            }
            let powerValues = items.compactMap { powerByProcess[$0.identity] }
            if !powerValues.isEmpty {
                groupPowerHistory[key, default: []].append(PerformancePoint(time: snapshot.timestamp, value: powerValues.reduce(0, +)))
                groupPowerHistory[key]?.removeAll { $0.time < cutoff }
            }
            let recentPower = (groupPowerHistory[key] ?? []).filter { $0.time >= snapshot.timestamp.addingTimeInterval(-60) }
            let groupPower: Double? = recentPower.isEmpty ? nil : recentPower.reduce(0) { $0 + $1.value } / Double(recentPower.count)
            let appPath = appPaths[key]
            let kind: MemoryGroupKind = appPath.map { regularApps.contains($0) ? .app : .backgroundApp } ?? .process
            built.append(MemoryGroup(
                id: key,
                name: appPath.map(AppBundleResolver.appName(for:)) ?? items[0].name,
                appPath: appPath,
                kind: kind,
                footprintBytes: total,
                processes: items.sorted { $0.footprintBytes > $1.footprintBytes },
                trend: MemoryHistory.trend(groupHistory[key] ?? []),
                recent: groupHistory[key] ?? [],
                cpu: groupCPU,
                cpuRecent: groupCPUHistory[key] ?? [],
                power: groupPower,
                energyJoules: Double(items.reduce(UInt64(0)) { $0 &+ $1.energyNanojoules }) / 1e9,
                powerRecent: groupPowerHistory[key] ?? []
            ))
        }
        for key in groupHistory.keys where buckets[key] == nil { groupHistory[key] = nil }
        for key in groupPowerHistory.keys where buckets[key] == nil { groupPowerHistory[key] = nil }
        for key in groupCPUHistory.keys where buckets[key] == nil { groupCPUHistory[key] = nil }
        groups = built.sorted { $0.footprintBytes > $1.footprintBytes }
        observations = rules.diagnose(
            system: cpuHistory,
            processes: groups.map { (id: $0.id, name: $0.name, points: $0.cpuRecent) },
            thermal: thermal
        )
        let ids = Set(observations.map(\.id))
        if !dismissed.isSubset(of: ids) { dismissed.formIntersection(ids) }
    }
}
