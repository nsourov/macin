import Darwin
import Foundation

public protocol ProcessMemoryProviding: Sendable {
    func samples() -> (samples: [ProcessMemorySample], coverage: ProcessCoverage)
}

public struct ProcessMemoryProvider: ProcessMemoryProviding {
    public init() {}

    public func samples() -> (samples: [ProcessMemorySample], coverage: ProcessCoverage) {
        let now = Date()
        let me = getuid()
        let pids = Self.allPIDs()
        var result: [ProcessMemorySample] = []
        result.reserveCapacity(pids.count)
        var denied = 0
        for pid in pids where pid > 0 {
            guard let usage = Self.rusage(pid) else {
                denied += 1
                continue
            }
            let path = Self.path(pid)
            let name = Self.name(pid) ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Process \(pid)"
            result.append(ProcessMemorySample(
                timestamp: now,
                identity: ProcessIdentity(pid: pid, startTime: usage.ri_proc_start_abstime),
                name: name,
                executablePath: path,
                isCurrentUser: Self.uid(pid) == me,
                footprintBytes: Int64(usage.ri_phys_footprint),
                lifetimePeakFootprintBytes: Int64(usage.ri_lifetime_max_phys_footprint),
                cpuTimeNanos: SystemCPU.nanos(fromMachTicks: usage.ri_user_time &+ usage.ri_system_time),
                energyNanojoules: usage.ri_energy_nj
            ))
        }
        return (result, ProcessCoverage(totalProcesses: pids.count, readableProcesses: result.count, deniedProcesses: denied))
    }

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func uid(_ pid: Int32) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }
}
