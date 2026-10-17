import Foundation

public enum MemoryTrend: Sendable, Equatable {
    case rising, falling, steady, unknown
}

public struct MemoryTrendRules: Sendable {
    public var minimumSamples = 5
    public var minimumSpan: TimeInterval = 20
    public var maximumGap: TimeInterval = 15
    public var relativeChange = 0.10
    public var absoluteChange: Int64 = 50 * 1_048_576

    public init() {}
}

public struct SystemMemoryPoint: Sendable, Equatable {
    public let time: Date
    public let usedBytes: Int64?
    public let compressedBytes: Int64?
    public let swapUsedBytes: Int64?
    public let pressure: MemoryPressureState
}

public struct MemoryHistory: Sendable {
    public struct Point: Sendable, Equatable {
        public let time: Date
        public let bytes: Int64

        public init(time: Date, bytes: Int64) {
            self.time = time
            self.bytes = bytes
        }
    }

    public let window: TimeInterval
    public private(set) var system: [SystemMemoryPoint] = []
    public private(set) var processes: [ProcessIdentity: [Point]] = [:]

    public init(window: TimeInterval = 300) {
        self.window = window
    }

    public mutating func record(_ snapshot: SystemMemorySnapshot, samples: [ProcessMemorySample]) {
        let now = snapshot.timestamp
        system.append(SystemMemoryPoint(time: now, usedBytes: snapshot.memoryUsedBytes, compressedBytes: snapshot.compressedMemoryBytes, swapUsedBytes: snapshot.swapUsedBytes, pressure: snapshot.pressure))
        let cutoff = now.addingTimeInterval(-window)
        system.removeAll { $0.time < cutoff }

        var alive = Set<ProcessIdentity>()
        for sample in samples {
            alive.insert(sample.identity)
            processes[sample.identity, default: []].append(Point(time: sample.timestamp, bytes: sample.footprintBytes))
        }
        for key in processes.keys {
            if !alive.contains(key) {
                processes[key] = nil
            } else {
                processes[key]?.removeAll { $0.time < cutoff }
            }
        }
    }

    public func points(for identity: ProcessIdentity) -> [Point] {
        processes[identity] ?? []
    }

    public static func trend(_ points: [Point], rules: MemoryTrendRules = MemoryTrendRules()) -> MemoryTrend {
        guard points.count >= rules.minimumSamples, let first = points.first, let last = points.last else { return .unknown }
        guard last.time.timeIntervalSince(first.time) >= rules.minimumSpan else { return .unknown }
        for (a, b) in zip(points, points.dropFirst()) where b.time.timeIntervalSince(a.time) > rules.maximumGap {
            return .unknown
        }
        let delta = last.bytes - first.bytes
        let base = Double(max(first.bytes, 1))
        if delta >= rules.absoluteChange && Double(delta) / base >= rules.relativeChange { return .rising }
        if -delta >= rules.absoluteChange && Double(-delta) / base >= rules.relativeChange { return .falling }
        return .steady
    }
}

public enum AppBundleResolver {
    public static func owningAppPath(for executablePath: String?) -> String? {
        guard let executablePath, let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    public static func appName(for appPath: String) -> String {
        let last = URL(fileURLWithPath: appPath).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}
