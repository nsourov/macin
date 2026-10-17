import Darwin
import Foundation

public struct SystemSnapshot: Sendable, Equatable {
    public enum Pressure: Sendable, Equatable {
        case normal, warning, critical
    }

    public let memoryUsed: Int64
    public let memoryTotal: Int64
    public let pressure: Pressure
    public let cpuLoad: Double
    public let uptime: TimeInterval
    public let chip: String
    public let osVersion: String

    public static func current() -> SystemSnapshot {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        return SystemSnapshot(
            memoryUsed: min(usedMemory(), total),
            memoryTotal: total,
            pressure: memoryPressure(),
            cpuLoad: cpuLoad(),
            uptime: ProcessInfo.processInfo.systemUptime,
            chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
            osVersion: osName()
        )
    }

    static func usedMemory() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Int64(vm_kernel_page_size)
        let appMemory = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        return (max(appMemory, 0) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
    }

    static func memoryPressure() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    static func cpuLoad() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        return min(loads[0] / cores, 1)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func osName() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "macOS \(v.majorVersion).\(v.minorVersion)"
    }
}
