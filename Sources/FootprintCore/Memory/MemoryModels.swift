import Foundation

public enum MemoryPressureState: String, Sendable, Codable, CaseIterable {
    case normal, warning, critical, unknown
}

public enum MetricAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

public struct SystemMemorySnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let physicalMemoryBytes: Int64
    public let pageSizeBytes: Int64
    public let appMemoryBytes: Int64?
    public let wiredMemoryBytes: Int64?
    public let compressedMemoryBytes: Int64?
    public let cachedFilesBytes: Int64?
    public let freeBytes: Int64?
    public let swapUsedBytes: Int64?
    public let swapTotalBytes: Int64?
    public let pressure: MemoryPressureState
    public let vmStatus: MetricAvailability
    public let swapStatus: MetricAvailability

    public var memoryUsedBytes: Int64? {
        guard let appMemoryBytes, let wiredMemoryBytes, let compressedMemoryBytes else { return nil }
        return appMemoryBytes + wiredMemoryBytes + compressedMemoryBytes
    }
}

public struct VMPageCounts: Sendable, Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var compressor: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var `internal`: UInt64

    public init(free: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64, compressor: UInt64, purgeable: UInt64, external: UInt64, internal: UInt64) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressor = compressor
        self.purgeable = purgeable
        self.external = external
        self.internal = `internal`
    }
}

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startTime: UInt64
}

public enum ProcessAccessStatus: Sendable, Equatable {
    case ok
    case denied
}

public struct ProcessMemorySample: Identifiable, Sendable, Equatable {
    public var id: ProcessIdentity { identity }
    public let timestamp: Date
    public let identity: ProcessIdentity
    public let name: String
    public let executablePath: String?
    public let isCurrentUser: Bool
    public let footprintBytes: Int64
    public let lifetimePeakFootprintBytes: Int64
    public var cpuTimeNanos: UInt64 = 0
    public var energyNanojoules: UInt64 = 0
}

public struct ProcessCoverage: Sendable, Equatable {
    public let totalProcesses: Int
    public let readableProcesses: Int
    public let deniedProcesses: Int
}
