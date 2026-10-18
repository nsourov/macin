import AppKit
import FootprintCore
import Foundation

enum SafeCommand {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 8) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationReason == .exit else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(decoding: data.prefix(16_000), as: UTF8.self))
            }
        }
    }

    static func lines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func pairs(_ text: String?, keep: [String]) -> [(String, String)] {
        lines(text).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty, keep.contains(parts[0]) else { return nil }
            return (parts[0], parts[1])
        }
    }
}

@MainActor
final class AgentToolbox {
    private weak var model: AppModel?
    private weak var monitor: SystemMonitor?
    private weak var battery: BatteryModel?
    private weak var network: NetworkModel?
    private weak var apps: ApplicationsModel?

    private(set) var facts: [Evidence] = []
    private(set) var trace: [AgentTraceItem] = []
    private(set) var toolsUsed: [String] = []
    var onChange: (([AgentTraceItem]) -> Void)?
    private var counter = 0
    private let maxCalls = 10
    private var cache: [String: String] = [:]

    var resultsText: String {
        facts.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
    }

    init(model: AppModel?, monitor: SystemMonitor?, battery: BatteryModel?, network: NetworkModel?, apps: ApplicationsModel?) {
        self.model = model
        self.monitor = monitor
        self.battery = battery
        self.network = network
        self.apps = apps
    }

    func run(_ name: String, _ argument: String?) async -> String {
        guard let spec = AgentTools.spec(name) else { return "Unknown tool \(name)." }
        let key = name + "|" + (argument ?? "").lowercased()
        if let cached = cache[key] { return cached }
        guard trace.count < maxCalls else { return "Tool limit reached. Answer with what you have." }
        trace.append(AgentTraceItem(tool: name, title: spec.title))
        onChange?(trace)
        let index = trace.count - 1
        var commands: [String] = []
        var lines: [(String, String)] = []

        switch name {
        case "system_info": lines = await systemInfo(&commands)
        case "memory_status": lines = await memoryStatus(&commands)
        case "processor_status": lines = await processorStatus(&commands)
        case "energy_by_app": lines = energyByApp()
        case "battery_status": lines = await batteryStatus(&commands)
        case "storage_status": lines = await storageStatus(&commands)
        case "network_status": lines = networkStatus()
        case "list_apps": lines = await listApps(argument)
        case "app_info": lines = await appInfo(argument)
        case "process_info": lines = await processInfo(argument, &commands)
        case "folder_size": lines = await folderSize(argument, &commands)
        default: break
        }

        trace[index].commands = commands
        trace[index].ok = !lines.isEmpty
        trace[index].done = true
        if !toolsUsed.contains(name) { toolsUsed.append(name) }
        onChange?(trace)

        if lines.isEmpty {
            cache[key] = "No information was found."
            return "No information was found."
        }
        var out: [String] = []
        for (title, value) in lines {
            counter += 1
            let clean = AssistantPrompt.clip(Redactor.redact(value), 400)
            facts.append(Evidence(id: "f\(counter)", module: spec.module, title: title, value: clean, level: .note))
            out.append("\(title): \(clean)")
        }
        let result = AssistantPrompt.clip(out.joined(separator: "\n"), 1500)
        cache[key] = result
        return result
    }

    private static func duration(since date: Date) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        f.allowedUnits = [.day, .hour, .minute]
        return f.string(from: date, to: Date()) ?? ""
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func systemInfo(_ commands: inout [String]) async -> [(String, String)] {
        var lines: [(String, String)] = []
        commands.append("sw_vers")
        lines += SafeCommand.pairs(await SafeCommand.run("/usr/bin/sw_vers", []), keep: ["ProductName", "ProductVersion", "BuildVersion"])
        let license = "/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/en.lproj/OSXSoftwareLicense.rtf"
        if let text = try? String(contentsOfFile: license, encoding: .utf8),
           let r = text.range(of: #"LICENSE AGREEMENT FOR macOS [A-Za-z]+(?: [A-Z][a-z]+)?"#, options: .regularExpression) {
            commands.append("read macOS name from Apple's license file")
            let name = String(text[r]).replacingOccurrences(of: "LICENSE AGREEMENT FOR ", with: "")
            lines.append(("macOS name (from Apple's license file)", name))
        }
        commands.append("system_profiler SPHardwareDataType")
        let hardware = await SafeCommand.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-detailLevel", "mini"], timeout: 10)
        lines += SafeCommand.pairs(hardware, keep: ["Model Name", "Model Identifier", "Chip", "Processor Name", "Processor Speed", "Total Number of Cores", "Memory"])
        commands.append("sysctl -n kern.boottime")
        if let out = await SafeCommand.run("/usr/sbin/sysctl", ["-n", "kern.boottime"]),
           let r = out.range(of: #"sec = \d+"#, options: .regularExpression),
           let sec = Double(out[r].dropFirst(6)) {
            let boot = Date(timeIntervalSince1970: sec)
            lines.append(("Last restart", boot.formatted(date: .abbreviated, time: .shortened)))
            lines.append(("On since last restart", Self.duration(since: boot)))
        }
        return lines
    }

    private func memoryStatus(_ commands: inout [String]) async -> [(String, String)] {
        var lines: [(String, String)] = []
        if let m = monitor, m.pressure != .unknown { lines.append(("Memory pressure level reported by macOS", m.pressure.rawValue)) }
        commands.append("memory_pressure -Q")
        if let free = SafeCommand.lines(await SafeCommand.run("/usr/bin/memory_pressure", ["-Q"])).last(where: { $0.contains("free percentage") }) {
            let parts = free.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { lines.append((parts[0], parts[1])) }
        }
        commands.append("top -l 1 -n 0")
        if let phys = SafeCommand.lines(await SafeCommand.run("/usr/bin/top", ["-l", "1", "-n", "0"])).first(where: { $0.hasPrefix("PhysMem:") }) {
            lines.append(("Physical memory (top)", String(phys.dropFirst(8)).trimmingCharacters(in: .whitespaces)))
        }
        commands.append("sysctl -n vm.swapusage")
        if let swap = await SafeCommand.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"])?.trimmingCharacters(in: .whitespacesAndNewlines), !swap.isEmpty {
            lines.append(("Swap (sysctl)", swap))
        }
        if let m = monitor {
            let top = m.groups.prefix(5).map { "\($0.name) \(ByteFormatter.memory($0.footprintBytes))" }
            if !top.isEmpty { lines.append(("Apps using the most memory", top.joined(separator: ", "))) }
        }
        return lines
    }

    private func processorStatus(_ commands: inout [String]) async -> [(String, String)] {
        var lines: [(String, String)] = []
        commands.append("top -l 1 -n 0")
        for line in SafeCommand.lines(await SafeCommand.run("/usr/bin/top", ["-l", "1", "-n", "0"])) {
            for key in ["Load Avg:", "CPU usage:", "Processes:"] where line.hasPrefix(key) {
                let value = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
                lines.append(("\(key.dropLast()) (top)", value))
                if key == "CPU usage:", let r = value.range(of: #"[\d.]+(?=% idle)"#, options: .regularExpression), let idle = Double(value[r]) {
                    lines.append(("Processor busy in total (100% minus idle)", String(format: "%.0f%%", 100 - idle)))
                }
            }
        }
        commands.append("sysctl -n hw.ncpu")
        if let cores = await SafeCommand.run("/usr/sbin/sysctl", ["-n", "hw.ncpu"])?.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.append(("Processor cores", cores))
        }
        commands.append("pmset -g therm")
        let therm = SafeCommand.lines(await SafeCommand.run("/usr/bin/pmset", ["-g", "therm"]))
        if !therm.isEmpty { lines.append(("pmset thermal report", therm.joined(separator: " · "))) }
        lines.append(("Thermal state reported by macOS", ThermalLevel(ProcessInfo.processInfo.thermalState).rawValue))
        if let t = monitor?.temperature.chip { lines.append(("Chip temperature sensor", String(format: "%.0f°C", t))) }
        commands.append("ps -Aceo pid,pcpu,rss,comm -r")
        let ps = SafeCommand.lines(await SafeCommand.run("/bin/ps", ["-Aceo", "pid,pcpu,rss,comm", "-r"])).dropFirst().prefix(5)
        let top = ps.compactMap { row -> String? in
            let cols = row.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            return cols.count == 4 ? "\(cols[3]) \(cols[1])%" : nil
        }
        if !top.isEmpty { lines.append(("Processes using the most processor (100% = one core)", top.joined(separator: ", "))) }
        if let busy = monitor?.observations.map(\.title), !busy.isEmpty {
            lines.append(("Macin noticed in the last minutes", busy.joined(separator: "; ")))
        }
        return lines
    }

    private func energyByApp() -> [(String, String)] {
        guard let m = monitor else { return [] }
        let ranked = m.groups.filter { ($0.power ?? 0) > 0 }.sorted { ($0.power ?? 0) > ($1.power ?? 0) }
        var lines: [(String, String)] = []
        if !ranked.isEmpty {
            lines.append(("Average power by app over the last minute (macOS energy counters)", ranked.prefix(6).map { "\($0.name) \(BatteryFormat.watts($0.power ?? 0))" }.joined(separator: ", ")))
        }
        lines.append(("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"))
        return lines
    }

    private func batteryStatus(_ commands: inout [String]) async -> [(String, String)] {
        var lines: [(String, String)] = []
        commands.append("pmset -g batt")
        let batt = SafeCommand.lines(await SafeCommand.run("/usr/bin/pmset", ["-g", "batt"]))
        if !batt.isEmpty { lines.append(("pmset battery report", batt.joined(separator: " · "))) }
        commands.append("system_profiler SPPowerDataType")
        let power = await SafeCommand.run("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 10)
        let labels = ["State of Charge (%)": "Charge level now (%)", "Cycle Count": "Battery cycle count", "Condition": "Battery condition reported by macOS",
                      "Maximum Capacity": "Battery health: maximum capacity compared to new", "Charging": "Charging", "Fully Charged": "Fully charged",
                      "Connected": "Power adapter connected", "Wattage (W)": "Power adapter wattage (W)"]
        var seen = Set<String>()
        for (key, value) in SafeCommand.pairs(power, keep: Array(labels.keys)) where seen.insert(key).inserted {
            lines.append((labels[key] ?? key, value))
        }
        lines.append(("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"))
        if let b = battery, b.snapshot.hasBattery {
            if let f = b.finding, f.level != .insufficient { lines.append(("Drain Macin measured recently", f.observation)) }
            lines.append(("Time on battery today (while Macin ran)", BatteryFormat.hours(b.timeOnBatteryToday)))
        }
        return lines
    }

    private func storageStatus(_ commands: inout [String]) async -> [(String, String)] {
        var lines: [(String, String)] = []
        var important: Int64?
        if let a = model {
            a.refreshVolume()
            if let v = a.volume {
                important = v.availableImportantBytes
                lines.append(("Free space (the number Finder and Macin show)", "\(ByteFormatter.string(v.availableImportantBytes)) free of \(ByteFormatter.string(v.totalBytes)) total"))
            }
        }
        commands.append("df -k /System/Volumes/Data")
        let df = SafeCommand.lines(await SafeCommand.run("/bin/df", ["-k", "/System/Volumes/Data"]))
        if df.count >= 2 {
            let cols = df[1].split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 5, let used = Int64(cols[2]), let free = Int64(cols[3]) {
                lines.append(("Used space (df)", "\(ByteFormatter.string(used * 1024)), \(cols[4]) of the disk"))
                lines.append(("Completely empty right now (df, not counting purgeable space)", ByteFormatter.string(free * 1024)))
                if let important, important > free * 1024 {
                    lines.append(("Purgeable space macOS can free by itself when needed", ByteFormatter.string(important - free * 1024)))
                }
            }
        }
        if let a = model {
            if a.planSummary.totalBytes > 0 { lines.append(("Safe to clean (from last scan)", ByteFormatter.string(a.planSummary.totalBytes))) }
            if a.trashBytes > 0 { lines.append(("In the Trash", ByteFormatter.string(a.trashBytes))) }
            let cats = a.lastCategoryTotals.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key.title) \(ByteFormatter.string($0.value))" }
            if !cats.isEmpty { lines.append(("Biggest kinds of files (last scan)", cats.joined(separator: ", "))) }
            lines.append(("Last storage scan", a.sessions.first.map { Self.relative($0.startedAt) } ?? "never"))
        }
        return lines
    }

    private func networkStatus() -> [(String, String)] {
        guard let n = network else { return [] }
        var lines: [(String, String)] = [("Network path (macOS)", n.path.status == .available ? "available\(n.path.primary.map { " via \($0.rawValue)" } ?? "")" : "not available")]
        if let w = n.wifi {
            var parts: [String] = []
            if let r = w.rssi { parts.append("signal \(r) dBm") }
            if let noise = w.noise { parts.append("noise \(noise) dBm") }
            if let rate = w.txRate { parts.append(String(format: "link rate %.0f Mbps", rate)) }
            if let b = w.band { parts.append(b) }
            if let c = w.channel { parts.append("channel \(c)") }
            if !parts.isEmpty { lines.append(("Wi-Fi (CoreWLAN)", parts.joined(separator: ", "))) }
        }
        if let f = n.finding {
            let when = n.lastRun.map { " (\(Self.relative($0)))" } ?? ""
            lines.append(("Last network check\(when)", "\(f.title). \(f.detail)"))
        } else {
            lines.append(("Last network check", "never run"))
        }
        if let median = n.latency?.median { lines.append(("Response time median", String(format: "%.0f ms", median * 1000))) }
        return lines
    }

    private func ensureApps() async -> ApplicationsModel? {
        guard let apps else { return nil }
        apps.loadIfNeeded()
        for _ in 0..<40 where apps.isLoading || apps.apps.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for _ in 0..<20 where apps.isMeasuring {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return apps
    }

    private func listApps(_ sort: String?) async -> [(String, String)] {
        guard let apps = await ensureApps(), !apps.apps.isEmpty else { return [] }
        let order = (sort ?? "size").lowercased()
        var list = apps.apps
        switch order {
        case "name": list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "running": list = list.filter { apps.running.contains($0.path) }
        default: list.sort { (apps.sizes[$0.path] ?? 0) > (apps.sizes[$1.path] ?? 0) }
        }
        var lines: [(String, String)] = [
            ("Installed apps", "\(apps.apps.count) (\(apps.apps.filter(\.isApple).count) from Apple)"),
            ("Apps open right now", "\(apps.apps.filter { apps.running.contains($0.path) }.count)")
        ]
        let rows = list.prefix(10).map { app -> String in
            let size = apps.sizes[app.path].map { ByteFormatter.string($0) } ?? "size unknown"
            return "\(app.name) \(size)\(apps.running.contains(app.path) ? " (open)" : "")"
        }
        lines.append((order == "running" ? "Open apps" : "Apps sorted by \(order)", rows.joined(separator: ", ")))
        return lines
    }

    private func appInfo(_ name: String?) async -> [(String, String)] {
        guard let query = name?.trimmingCharacters(in: .whitespaces).lowercased(), !query.isEmpty,
              let apps = await ensureApps() else { return [] }
        let matches = apps.apps.filter { $0.name.lowercased() == query } + apps.apps.filter { $0.name.lowercased().contains(query) && $0.name.lowercased() != query }
        guard let app = matches.first else {
            return [("App lookup", "no installed app named \(name ?? "")")]
        }
        await apps.measureIfNeeded(app)
        var lines: [(String, String)] = [("App", app.name)]
        if let v = app.version { lines.append(("Version", v)) }
        if let id = app.bundleID { lines.append(("Bundle ID", id)) }
        lines.append(("Location", app.path))
        if let size = apps.sizes[app.path] { lines.append(("App size", ByteFormatter.string(size))) }
        let data = await apps.relatedItems(for: app).reduce(0) { $0 + $1.bytes }
        lines.append(("Data it keeps in Library folders", ByteFormatter.string(data)))
        let running = apps.running.contains(app.path)
        lines.append(("Open right now", running ? "yes" : "no"))
        if running, let g = monitor?.groups.first(where: { $0.appPath == app.path }) {
            lines.append(("Memory now", ByteFormatter.memory(g.footprintBytes)))
            if let c = g.cpu { lines.append(("Processor now (100% = one core)", String(format: "%.0f%%", c * 100))) }
            if let p = g.power { lines.append(("Average power now", BatteryFormat.watts(p))) }
        }
        return lines
    }

    private func processInfo(_ name: String?, _ commands: inout [String]) async -> [(String, String)] {
        guard let query = name?.trimmingCharacters(in: .whitespaces).lowercased(), !query.isEmpty else { return [] }
        commands.append("ps -Aceo pid,pcpu,rss,comm")
        let rows = SafeCommand.lines(await SafeCommand.run("/bin/ps", ["-Aceo", "pid,pcpu,rss,comm", "-r"])).dropFirst().compactMap { row -> (String, String)? in
            let cols = row.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4, cols[3].lowercased().contains(query), let kb = Int64(cols[2]) else { return nil }
            return ("\(cols[3]) (PID \(cols[0]))", "processor \(cols[1])% (100% = one core), memory \(ByteFormatter.memory(kb * 1024))")
        }
        return rows.isEmpty ? [("Process lookup", "no running process matches \(name ?? "")")] : Array(rows.prefix(6))
    }

    private func folderSize(_ raw: String?, _ commands: inout [String]) async -> [(String, String)] {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return [] }
        let home = NSHomeDirectory()
        let expanded = raw.hasPrefix("~") ? home + raw.dropFirst() : (raw.hasPrefix("/") ? raw : home + "/" + raw)
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard url.path == home || url.path.hasPrefix(home + "/") else { return [("Folder size", "only folders inside the home folder can be measured")] }
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [("Folder size", "that folder doesn't exist")] }
        commands.append("du -sk \(Redactor.redact(url.path))")
        guard let out = await SafeCommand.run("/usr/bin/du", ["-sk", url.path], timeout: 20),
              let kb = out.split(separator: "\t").first.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) else {
            return [("Folder size", "du didn't finish in time")]
        }
        return [("Folder", url.path), ("Folder size (du)", ByteFormatter.string(kb * 1024))]
    }
}
