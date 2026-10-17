import Charts
import FootprintCore
import SwiftUI

enum PerformanceTab: String, ModuleTab {
    case overview = "Overview"
    case processes = "Processes"

    var title: String { rawValue }
}

enum CPUFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        let p = value * 100
        if p < 0.05 { return "0%" }
        return p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(Int(seconds)) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }
}

enum TempFormat {
    static func string(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded()))°C"
    }

    static func color(_ value: Double?) -> Color {
        guard let value else { return Palette.slate }
        if value < 70 { return Palette.emerald }
        if value < 90 { return Palette.amber }
        return Palette.coral
    }

    static func heat(_ thermal: ThermalLevel, _ reading: TemperatureReading) -> String {
        guard let chip = reading.chip else { return thermal.title }
        return "\(thermal.title) · \(string(chip))"
    }
}

extension ThermalLevel {
    var title: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .nominal: return Palette.emerald
        case .fair: return Palette.sky
        case .serious: return Palette.amber
        case .critical: return Palette.coral
        case .unknown: return Palette.slate
        }
    }

    var explanation: String {
        switch self {
        case .nominal: return "macOS reports a normal heat level."
        case .fair: return "macOS reports the Mac is a little warm. This is common during work and nothing to worry about."
        case .serious: return "macOS reports the Mac is hot and may slow down to cool itself."
        case .critical: return "macOS reports the Mac is very hot and is slowing down to cool itself."
        case .unknown: return "macOS has not reported a heat level."
        }
    }

    var step: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        case .unknown: return -1
        }
    }
}

extension PerformanceObservation {
    var title: String {
        switch kind {
        case .thermal(let level): return level == .critical ? "Your Mac is very hot" : "Your Mac is running hot"
        case .sustainedSystem: return "Processor busy for \(CPUFormat.duration(duration))"
        case .sustainedProcess(let name): return "\(name) is keeping the processor busy"
        }
    }

    var detail: String {
        switch kind {
        case .thermal(let level): return level.explanation
        case .sustainedSystem: return "On average \(CPUFormat.percent(average)) of all cores were busy over the last \(CPUFormat.duration(duration))."
        case .sustainedProcess: return "It used about \(CPUFormat.percent(average)) for \(CPUFormat.duration(duration)). 100% means one full core."
        }
    }

    var why: String {
        switch kind {
        case .thermal: return "When a Mac gets hot, macOS lowers speed to protect it. Things can feel slower until it cools."
        case .sustainedSystem: return "When the processor stays busy, apps can feel slow and the fans may spin up."
        case .sustainedProcess: return "One app working hard for a long time can slow other apps down and use more battery."
        }
    }

    var possibilities: [String] {
        switch kind {
        case .thermal: return ["A heavy task such as a build, export or game", "Blocked air vents or a warm room", "Charging while working hard"]
        case .sustainedSystem: return ["A build, export, backup or sync is running", "An app is busy in the background"]
        case .sustainedProcess: return ["It is doing real work, like a build, video or indexing", "It may be stuck doing the same thing over and over"]
        }
    }

    var steps: [String] {
        switch kind {
        case .thermal: return ["Pause or finish heavy tasks", "Put the Mac on a hard surface with space around it", "Give it a few minutes to cool down"]
        case .sustainedSystem: return ["Look at the apps at the top of the list", "Wait for big tasks to finish"]
        case .sustainedProcess(let name): return ["Check whether \(name) is doing something you expect", "If you don't need it, save your work and quit it"]
        }
    }

    var color: Color {
        if case .thermal(let level) = kind { return level.color }
        return Palette.amber
    }

    var symbol: String {
        switch kind {
        case .thermal: return "thermometer.high"
        case .sustainedSystem: return "cpu"
        case .sustainedProcess: return "flame"
        }
    }
}

struct PerformanceView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var tab: PerformanceTab = .overview

    var body: some View {
        Group {
            switch tab {
            case .overview: PerformanceOverview(tab: $tab)
            case .processes: PerformanceProcessList()
            }
        }
        .moduleTabs($tab)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

struct PerformanceOverview: View {
    @Binding var tab: PerformanceTab
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var apps: ApplicationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Performance", subtitle: "What is keeping your Mac busy, and whether it is a problem.")
                statusCard
                HStack(alignment: .top, spacing: 18) {
                    chartCard
                    stateCard.frame(width: 340)
                }
                topCard
                footer
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private var statusCard: some View {
        let list = monitor.visibleObservations
        let primary = list.first
        let color = primary?.color ?? Palette.emerald
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: primary?.symbol ?? "checkmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(color.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(primary?.title ?? "No sustained issue")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    Text(primary?.detail ?? "Nothing has stayed busy in the last few minutes. Short spikes are normal.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let primary {
                        HStack(spacing: 10) {
                            ObservationDetailButton(observation: primary)
                            Button("Not relevant") { withAnimation(Motion.snappy) { monitor.dismiss(primary) } }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    stat("Processor", CPUFormat.percent(monitor.cpuUsage))
                    stat("Heat", TempFormat.heat(monitor.thermal, monitor.temperature))
                    stat("Low Power Mode", monitor.lowPowerMode ? "On" : "Off")
                }
            }
            if list.count > 1 {
                Divider()
                ForEach(list.dropFirst().prefix(2)) { obs in
                    HStack(spacing: 10) {
                        Image(systemName: obs.symbol).foregroundStyle(obs.color).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(obs.title).font(.callout.weight(.medium))
                            Text(obs.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ObservationDetailButton(observation: obs)
                    }
                }
            }
        }
        .card(padding: 20)
        .animation(Motion.smooth, value: list.map(\.id))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private var chartCard: some View {
        let points = monitor.cpuHistory
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 5 minutes").font(.headline)
                InfoButton(text: "How busy all processor cores are together. 100% means every core is fully busy.")
                Spacer()
                Text("All cores").font(.caption).foregroundStyle(.secondary)
            }
            if points.count < 2 {
                Text("Collecting samples…").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Time", p.time), y: .value("Busy", p.value * 100))
                            .foregroundStyle(LinearGradient(colors: [Palette.amber.opacity(0.3), Palette.amber.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.time), y: .value("Busy", p.value * 100))
                            .foregroundStyle(Palette.amber)
                            .interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Busy line", 80))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Very busy").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Int.self) { Text("\(d)%") } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .minute)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 180)
                .accessibilityLabel("Processor use over the last 5 minutes")
            }
        }
        .card(padding: 20)
    }

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Heat").font(.headline)
                InfoButton(text: "The heat level comes from macOS. Temperatures come from the sensors inside your Mac. Chips often run at 40–90°C while working, which is normal.")
                Spacer()
                Text(monitor.thermal.title).font(.callout.weight(.semibold)).foregroundStyle(monitor.thermal.color)
            }
            if !monitor.temperature.isEmpty {
                HStack(spacing: 8) {
                    tempTile("Chip", "cpu", monitor.temperature.chip)
                    tempTile("Battery", "battery.75percent", monitor.temperature.battery)
                    tempTile("Storage", "internaldrive", monitor.temperature.storage)
                }
                if monitor.chipTempHistory.count > 1 {
                    let values = monitor.chipTempHistory.map(\.value)
                    let low = ((values.min() ?? 0) - 4).rounded(.down)
                    let high = ((values.max() ?? 100) + 4).rounded(.up)
                    Chart(Array(monitor.chipTempHistory.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Time", p.time), yStart: .value("Base", low), yEnd: .value("Chip", p.value))
                            .foregroundStyle(LinearGradient(colors: [TempFormat.color(monitor.temperature.chip).opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.time), y: .value("Chip", p.value))
                            .foregroundStyle(TempFormat.color(monitor.temperature.chip))
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: low...high)
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } } } }
                    .frame(height: 54)
                    .accessibilityLabel("Chip temperature over the last 5 minutes")
                }
            }
            HStack(spacing: 4) {
                ForEach([ThermalLevel.nominal, .fair, .serious, .critical], id: \.self) { level in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(level.step <= monitor.thermal.step ? level.color : Color.primary.opacity(0.08))
                            .frame(height: 6)
                        Text(level.title).font(.caption2).foregroundStyle(level == monitor.thermal ? .primary : .secondary)
                    }
                }
            }
            Text(monitor.thermal.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Label("Low Power Mode", systemImage: monitor.lowPowerMode ? "leaf.fill" : "leaf")
                    .font(.callout)
                    .foregroundStyle(monitor.lowPowerMode ? Palette.emerald : .primary)
                Spacer()
                Text(monitor.lowPowerMode ? "On" : "Off").font(.callout.weight(.semibold))
            }
            Text(monitor.lowPowerMode
                 ? "Your Mac is saving energy, so heavy tasks may take longer."
                 : "Your Mac is running at full speed.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Label("Cores", systemImage: "cpu").font(.callout)
                Spacer()
                Text("\(SystemCPU.logicalCores)").font(.callout.weight(.semibold))
            }
        }
        .card(padding: 20)
    }

    private func tempTile(_ title: String, _ symbol: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(TempFormat.string(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : TempFormat.color(value))
                .numeric()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var topCard: some View {
        let top = Array(monitor.groups.filter { ($0.cpu ?? 0) > 0 }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Using the most processor").font(.headline)
                InfoButton(text: "100% means one full core, like in Activity Monitor. Apps that use several cores can go above 100%. Your Mac has \(SystemCPU.logicalCores) cores.")
                Spacer()
                Button("See all") { tab = .processes }.buttonStyle(.link)
            }
            if top.isEmpty {
                Text("Collecting samples…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(top) { group in
                AppRowButton(appPath: group.appPath) {
                    HStack(spacing: 10) {
                        MemoryAppIcon(appPath: group.appPath)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(group.processes.count > 1 ? "\(group.kind.rawValue) · \(group.processes.count) processes" : group.kind.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        MemorySparkline(points: group.cpuRecent.map { MemoryHistory.Point(time: $0.time, bytes: Int64($0.value * 1000)) }, trend: .steady)
                            .frame(width: 130, height: 28)
                        Text(CPUFormat.percent(group.cpu)).font(.callout.weight(.semibold)).monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
            if monitor.visibleObservations.isEmpty {
                Text("Shown for context. Nothing has stayed busy, so there is no need to close anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Updates every 2 seconds\(monitor.snapshot.map { ", last at \($0.timestamp.formatted(date: .omitted, time: .standard))" } ?? ""). macOS system processes are hidden from apps, so their processor use is not listed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ObservationDetailButton: View {
    let observation: PerformanceObservation
    @State private var shown = false

    var body: some View {
        Button("Why?") { shown.toggle() }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $shown) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(observation.title).font(.headline)
                    section("What we saw", [observation.detail])
                    section("Why it may matter", [observation.why])
                    section("Possible reasons", observation.possibilities)
                    section("What you can do", observation.steps)
                    Text(observation.confidence.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(width: 320)
            }
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                Text(lines.count > 1 ? "• \(line)" : line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PerformanceProcessList: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var search = ""
    @State private var grouped = true
    @State private var sortOrder = [KeyPathComparator(\CPURow.cpu, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Performance", subtitle: "Apps and processes, busiest first.")
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find an app or process", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .frame(maxWidth: 300)
                Spacer()
                Toggle("Group by app", isOn: $grouped).toggleStyle(.switch).controlSize(.small)
            }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 8) {
                        MemoryAppIcon(appPath: row.appPath, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.name).lineLimit(1)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 180)
                TableColumn("Processor", value: \.cpu) { row in
                    Text(CPUFormat.percent(row.cpu)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(100)
                TableColumn("Average (5 min)", value: \.average) { row in
                    Text(row.hasAverage ? CPUFormat.percent(row.average) : "–").monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(120)
                TableColumn("Memory", value: \.bytes) { row in
                    Text(MemoryFormat.bytes(row.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(100)
            }
            Text("Processor: 100% means one full core, like in Activity Monitor. Your Mac has \(SystemCPU.logicalCores) cores, so the most possible is \(SystemCPU.logicalCores * 100)%.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var rows: [CPURow] {
        var result: [CPURow]
        if grouped {
            result = monitor.groups.map { g in
                let avg = g.cpuRecent.isEmpty ? 0 : g.cpuRecent.reduce(0) { $0 + $1.value } / Double(g.cpuRecent.count)
                return CPURow(id: g.id, name: g.name, appPath: g.appPath, detail: g.processes.count > 1 ? "\(g.kind.rawValue) · \(g.processes.count) processes" : g.kind.rawValue,
                              cpu: g.cpu ?? 0, average: avg, hasAverage: !g.cpuRecent.isEmpty, bytes: g.footprintBytes)
            }
        } else {
            let paths = Dictionary(uniqueKeysWithValues: monitor.groups.flatMap { g in g.processes.map { ($0.identity, g.appPath) } })
            result = monitor.processes.map { r in
                CPURow(id: "\(r.sample.identity.pid)-\(r.sample.identity.startTime)", name: r.sample.name, appPath: paths[r.sample.identity] ?? nil,
                       detail: "PID \(r.sample.identity.pid)", cpu: r.cpu ?? 0, average: 0, hasAverage: false, bytes: r.sample.footprintBytes)
            }
        }
        if !search.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        return result.sorted(using: sortOrder)
    }
}

struct CPURow: Identifiable {
    let id: String
    let name: String
    let appPath: String?
    let detail: String
    let cpu: Double
    let average: Double
    let hasAverage: Bool
    let bytes: Int64
}
