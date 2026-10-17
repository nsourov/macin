import Darwin
import Foundation

public protocol SystemMemoryProviding: Sendable {
    func snapshot(pressure: MemoryPressureState) -> SystemMemorySnapshot
}

public struct SystemMemoryProvider: SystemMemoryProviding {
    public init() {}

    public func snapshot(pressure: MemoryPressureState) -> SystemMemorySnapshot {
        let physical = Self.physicalMemory()
        let page = Int64(vm_kernel_page_size)
        let pages = Self.pageCounts()
        let swap = Self.swapUsage()
        let breakdown = pages.map { Self.breakdown($0, pageSize: page) }
        return SystemMemorySnapshot(
            timestamp: Date(),
            physicalMemoryBytes: physical,
            pageSizeBytes: page,
            appMemoryBytes: breakdown?.app,
            wiredMemoryBytes: breakdown?.wired,
            compressedMemoryBytes: breakdown?.compressed,
            cachedFilesBytes: breakdown?.cached,
            freeBytes: breakdown?.free,
            swapUsedBytes: swap?.used,
            swapTotalBytes: swap?.total,
            pressure: pressure,
            vmStatus: pages == nil ? .unavailable("macOS did not return memory page statistics") : .available,
            swapStatus: swap == nil ? .unavailable("macOS did not return swap usage") : .available
        )
    }

    public static func breakdown(_ p: VMPageCounts, pageSize: Int64) -> (app: Int64, wired: Int64, compressed: Int64, cached: Int64, free: Int64) {
        let app = Int64(p.internal) - Int64(p.purgeable)
        let cached = Int64(p.external) + Int64(p.purgeable)
        return (
            app: max(app, 0) * pageSize,
            wired: Int64(p.wired) * pageSize,
            compressed: Int64(p.compressor) * pageSize,
            cached: cached * pageSize,
            free: Int64(p.free + p.speculative) * pageSize
        )
    }

    public static func physicalMemory() -> Int64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 { return Int64(value) }
        return Int64(ProcessInfo.processInfo.physicalMemory)
    }

    static func pageCounts() -> VMPageCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count),
            internal: UInt64(stats.internal_page_count)
        )
    }

    static func swapUsage() -> (used: Int64, total: Int64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    public static func currentPressureLevel() -> MemoryPressureState {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        return pressure(fromLevel: level)
    }

    public static func pressure(fromLevel level: Int32) -> MemoryPressureState {
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }
}
