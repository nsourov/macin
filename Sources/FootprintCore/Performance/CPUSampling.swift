import Darwin
import Foundation

public struct CPUTicks: Sendable, Equatable {
    public var busy: UInt64
    public var total: UInt64

    public init(busy: UInt64, total: UInt64) {
        self.busy = busy
        self.total = total
    }
}

public struct PerformancePoint: Sendable, Equatable {
    public let time: Date
    public let value: Double

    public init(time: Date, value: Double) {
        self.time = time
        self.value = value
    }
}

public enum ThermalLevel: String, Sendable, CaseIterable {
    case nominal, fair, serious, critical, unknown

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }

    public var isElevated: Bool { self == .serious || self == .critical }
}

public enum SystemCPU {
    public static func ticks() -> CPUTicks? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(busy: busy, total: total)
    }

    public static func usage(from a: CPUTicks, to b: CPUTicks) -> Double? {
        guard b.total > a.total, b.busy >= a.busy else { return nil }
        let value = Double(b.busy - a.busy) / Double(b.total - a.total)
        return min(max(value, 0), 1)
    }

    public static func processUsage(fromNanos a: UInt64, at t0: Date, toNanos b: UInt64, at t1: Date) -> Double? {
        let wall = t1.timeIntervalSince(t0)
        guard wall >= 0.5, b >= a else { return nil }
        return Double(b - a) / 1_000_000_000 / wall
    }

    public static var logicalCores: Int { max(ProcessInfo.processInfo.activeProcessorCount, 1) }

    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    static func nanos(fromMachTicks ticks: UInt64) -> UInt64 {
        let (q, r) = ticks.quotientAndRemainder(dividingBy: timebase.denom)
        return q * timebase.numer + r * timebase.numer / timebase.denom
    }
}

public enum PerformanceConfidence: String, Sendable {
    case high = "High confidence"
    case medium = "Medium confidence"
    case low = "Low confidence"
}

public struct PerformanceObservation: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case thermal(ThermalLevel)
        case sustainedSystem
        case sustainedProcess(String)
    }

    public let id: String
    public let kind: Kind
    public let average: Double
    public let duration: TimeInterval
    public let confidence: PerformanceConfidence
}

public struct PerformanceRules: Sendable {
    public var systemThreshold = 0.8
    public var processThreshold = 0.8
    public var minimumDuration: TimeInterval = 30
    public var hysteresis = 0.1
    public var maximumGap: TimeInterval = 10

    public init() {}

    public func sustained(_ points: [PerformancePoint], threshold: Double) -> (duration: TimeInterval, average: Double)? {
        guard let last = points.last, last.value >= threshold - hysteresis else { return nil }
        var start = points.count - 1
        while start > 0 {
            let previous = points[start - 1]
            guard previous.value >= threshold - hysteresis,
                  points[start].time.timeIntervalSince(previous.time) <= maximumGap else { break }
            start -= 1
        }
        let run = points[start...]
        let duration = last.time.timeIntervalSince(run.first!.time)
        let average = run.reduce(0) { $0 + $1.value } / Double(run.count)
        guard duration >= minimumDuration, average >= threshold else { return nil }
        return (duration, average)
    }

    public func diagnose(system: [PerformancePoint], processes: [(id: String, name: String, points: [PerformancePoint])], thermal: ThermalLevel) -> [PerformanceObservation] {
        var result: [PerformanceObservation] = []
        if thermal.isElevated {
            result.append(PerformanceObservation(id: "thermal", kind: .thermal(thermal), average: 0, duration: 0, confidence: .high))
        }
        if let run = sustained(system, threshold: systemThreshold) {
            result.append(PerformanceObservation(id: "system", kind: .sustainedSystem, average: run.average, duration: run.duration, confidence: .high))
        }
        let busy = processes.compactMap { p -> PerformanceObservation? in
            guard let run = sustained(p.points, threshold: processThreshold) else { return nil }
            return PerformanceObservation(id: "proc:" + p.id, kind: .sustainedProcess(p.name), average: run.average, duration: run.duration, confidence: .medium)
        }
        result += busy.sorted { $0.average > $1.average }.prefix(3)
        return result
    }
}
