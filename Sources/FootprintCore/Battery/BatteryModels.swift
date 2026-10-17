import Foundation
import IOKit.ps

public enum ChargingState: String, Sendable, Codable {
    case charging, discharging, charged, pluggedNotCharging, unknown
}

public enum PowerSourceKind: String, Sendable, Codable {
    case battery, external, unknown
}

public struct BatterySnapshot: Sendable, Equatable {
    public var timestamp: Date
    public var hasBattery: Bool
    public var chargePercent: Int?
    public var state: ChargingState
    public var source: PowerSourceKind
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var condition: String?
    public var lowPowerMode: Bool

    public init(timestamp: Date = Date(), hasBattery: Bool, chargePercent: Int? = nil, state: ChargingState = .unknown, source: PowerSourceKind = .unknown, minutesToEmpty: Int? = nil, minutesToFull: Int? = nil, condition: String? = nil, lowPowerMode: Bool = false) {
        self.timestamp = timestamp
        self.hasBattery = hasBattery
        self.chargePercent = chargePercent
        self.state = state
        self.source = source
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.condition = condition
        self.lowPowerMode = lowPowerMode
    }

    public static func parse(_ description: [String: Any]?, at time: Date = Date(), lowPowerMode: Bool = false) -> BatterySnapshot {
        guard let d = description, (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType, (d[kIOPSIsPresentKey] as? Bool) ?? true else {
            return BatterySnapshot(timestamp: time, hasBattery: false, lowPowerMode: lowPowerMode)
        }
        var percent: Int?
        if let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
            percent = Swift.max(0, Swift.min(100, Int((Double(current) / Double(max) * 100).rounded())))
        }
        let sourceState = d[kIOPSPowerSourceStateKey] as? String
        let source: PowerSourceKind = sourceState == kIOPSACPowerValue ? .external : (sourceState == kIOPSBatteryPowerValue ? .battery : .unknown)
        let charging = d[kIOPSIsChargingKey] as? Bool
        let charged = d[kIOPSIsChargedKey] as? Bool
        let state: ChargingState
        if charged == true { state = .charged }
        else if charging == true { state = .charging }
        else if source == .battery { state = .discharging }
        else if source == .external { state = .pluggedNotCharging }
        else { state = .unknown }

        func minutes(_ key: String) -> Int? {
            guard let v = d[key] as? Int, v > 0, v < 60 * 48 else { return nil }
            return v
        }
        let condition = (d[kIOPSBatteryHealthKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BatterySnapshot(
            timestamp: time,
            hasBattery: true,
            chargePercent: percent,
            state: state,
            source: source,
            minutesToEmpty: state == .discharging ? minutes(kIOPSTimeToEmptyKey) : nil,
            minutesToFull: state == .charging ? minutes(kIOPSTimeToFullChargeKey) : nil,
            condition: condition,
            lowPowerMode: lowPowerMode
        )
    }
}

public enum BatteryProvider {
    public static func current() -> BatterySnapshot {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatterySnapshot(hasBattery: false, lowPowerMode: lpm) }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let snap = BatterySnapshot.parse(desc, lowPowerMode: lpm)
            if snap.hasBattery { return snap }
        }
        return BatterySnapshot(hasBattery: false, lowPowerMode: lpm)
    }
}

public struct BatterySample: Sendable, Equatable {
    public let time: Date
    public let percent: Int
    public let onBattery: Bool
    public let charging: Bool
    public let cpu: Double?

    public init(time: Date, percent: Int, onBattery: Bool, charging: Bool, cpu: Double? = nil) {
        self.time = time
        self.percent = percent
        self.onBattery = onBattery
        self.charging = charging
        self.cpu = cpu
    }
}

public struct BatteryEvent: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case pluggedIn, unplugged, gap }
    public var id: Date { time }
    public let time: Date
    public let kind: Kind
    public let percent: Int?
}

public struct DrainFinding: Sendable, Equatable {
    public enum Level: String, Sendable { case normal, worthReviewing, insufficient }
    public let level: Level
    public let observation: String
    public let window: String
    public let context: String
    public let confidence: String
    public let nextStep: String
    public let limitations: String
    public let ratePerHour: Double?
}

public enum BatteryAnalysis {
    public static let maxGap: TimeInterval = 15 * 60

    public static func events(_ samples: [BatterySample]) -> [BatteryEvent] {
        var out: [BatteryEvent] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            if b.time.timeIntervalSince(a.time) > maxGap {
                out.append(BatteryEvent(time: a.time, kind: .gap, percent: nil))
            }
            if a.onBattery && !b.onBattery { out.append(BatteryEvent(time: b.time, kind: .pluggedIn, percent: b.percent)) }
            if !a.onBattery && b.onBattery { out.append(BatteryEvent(time: b.time, kind: .unplugged, percent: b.percent)) }
        }
        return out
    }

    public static func dischargeSegments(_ samples: [BatterySample]) -> [[BatterySample]] {
        var segments: [[BatterySample]] = []
        var current: [BatterySample] = []
        for s in samples {
            if let last = current.last, !s.onBattery || s.time.timeIntervalSince(last.time) > maxGap || s.percent > last.percent {
                if current.count > 1 { segments.append(current) }
                current = []
            }
            if s.onBattery { current.append(s) }
        }
        if current.count > 1 { segments.append(current) }
        return segments
    }

    public static func rate(_ segment: [BatterySample]) -> Double? {
        guard let first = segment.first, let last = segment.last else { return nil }
        let hours = last.time.timeIntervalSince(first.time) / 3600
        guard hours > 0 else { return nil }
        return Double(first.percent - last.percent) / hours
    }

    public static func diagnose(_ samples: [BatterySample], now: Date = Date()) -> DrainFinding {
        let segments = dischargeSegments(samples)
        let limitations = "This uses changes in charge level only. It cannot tell exactly how much power each app used."
        guard let latest = segments.last, let first = latest.first, let last = latest.last,
              last.time.timeIntervalSince(first.time) >= 15 * 60, latest.count >= 3,
              let perHour = rate(latest) else {
            return DrainFinding(level: .insufficient,
                                observation: "Not enough time on battery has been recorded yet.",
                                window: "Needs at least 15 minutes unplugged with Macin running.",
                                context: "History started when Macin was first opened. Earlier history is not available.",
                                confidence: "Low — too few samples",
                                nextStep: "Use your Mac on battery for a while, then check again.",
                                limitations: limitations,
                                ratePerHour: nil)
        }
        let minutes = Int(last.time.timeIntervalSince(first.time) / 60)
        let drop = first.percent - last.percent
        let cpus = latest.compactMap(\.cpu)
        let avgCPU = cpus.isEmpty ? nil : cpus.reduce(0, +) / Double(cpus.count)
        let busy = (avgCPU ?? 0) > 0.4

        let older = segments.dropLast().compactMap { seg -> Double? in
            guard let f = seg.first, let l = seg.last, l.time.timeIntervalSince(f.time) >= 15 * 60 else { return nil }
            return rate(seg)
        }.sorted()
        let baseline = older.isEmpty ? nil : older[older.count / 2]

        let fast: Bool
        if let baseline, baseline > 0 { fast = perHour > max(baseline * 1.6, baseline + 5) }
        else { fast = perHour > 20 }

        var confidence = latest.count >= 10 && minutes >= 45 ? "High" : (minutes >= 25 ? "Medium" : "Low")
        confidence += " — \(latest.count) samples over \(minutes) minutes"
        let context: String
        if let avgCPU {
            context = "Processor was \(Int(avgCPU * 100))% busy on average in this window." + (busy ? " That is a heavy workload." : "")
        } else {
            context = "No processor data was recorded for this window."
        }
        let baselineText = baseline.map { String(format: " Your usual rate is about %.0f%% per hour.", $0) } ?? ""
        let observation = String(format: "Charge went down %d%% in %d minutes (about %.0f%% per hour).", drop, minutes, perHour) + baselineText

        if fast {
            return DrainFinding(level: .worthReviewing,
                                observation: observation,
                                window: "\(first.time.formatted(date: .omitted, time: .shortened)) to \(last.time.formatted(date: .omitted, time: .shortened)) while unplugged",
                                context: context,
                                confidence: confidence,
                                nextStep: busy
                                    ? "Open Performance to see which apps keep the processor busy. Closing heavy apps can help."
                                    : "Check screen brightness and apps running in the background. You can also check battery condition in System Settings → Battery.",
                                limitations: limitations,
                                ratePerHour: perHour)
        }
        return DrainFinding(level: .normal,
                            observation: observation,
                            window: "\(first.time.formatted(date: .omitted, time: .shortened)) to \(last.time.formatted(date: .omitted, time: .shortened)) while unplugged",
                            context: context,
                            confidence: confidence,
                            nextStep: "Nothing to do. Battery use looks normal.",
                            limitations: limitations,
                            ratePerHour: perHour)
    }
}

public struct LowBatteryAlert: Sendable {
    public var threshold: Int
    public var armed = true

    public init(threshold: Int) {
        self.threshold = threshold
    }

    public mutating func shouldNotify(_ snap: BatterySnapshot) -> Bool {
        guard let p = snap.chargePercent else { return false }
        if snap.source == .external || p >= threshold + 5 {
            armed = true
            return false
        }
        if armed && snap.source == .battery && p <= threshold {
            armed = false
            return true
        }
        return false
    }
}
