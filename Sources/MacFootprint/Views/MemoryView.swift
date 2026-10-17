import Charts
import FootprintCore
import SwiftUI

enum MemoryTab: String, ModuleTab {
    case overview = "Overview"
    case apps = "Apps"

    var title: String { rawValue }
}

struct MemoryView: View {
    @EnvironmentObject private var memory: SystemMonitor
    @State private var tab: MemoryTab = .overview

    var body: some View {
        Group {
            if let snapshot = memory.snapshot {
                switch tab {
                case .overview: MemoryOverview(snapshot: snapshot, tab: $tab)
                case .apps: MemoryAppsList(tab: $tab)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading memory…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .moduleTabs($tab)
        .onAppear { memory.start() }
        .onDisappear { memory.stop() }
    }
}

enum MemoryFormat {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func percent(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "–" }
        let p = Double(value) / Double(total) * 100
        return p < 0.1 ? "<0.1%" : String(format: "%.1f%%", p)
    }
}

extension MemoryPressureState {
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .normal: return Palette.emerald
        case .warning: return Palette.amber
        case .critical: return Palette.coral
        case .unknown: return Palette.slate
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var explanation: String {
        switch self {
        case .normal: return "Memory is in use, but macOS reports normal pressure. No action is recommended."
        case .warning: return "macOS reports elevated memory pressure. Review the apps using the most memory and close one you no longer need."
        case .critical: return "macOS reports critical memory pressure. Save your work and consider closing an app you no longer need."
        case .unknown: return "macOS has not reported memory pressure yet."
        }
    }
}

struct TrendBadge: View {
    let trend: MemoryTrend

    var body: some View {
        switch trend {
        case .rising:
            Label("Growing", systemImage: "arrow.up.right").foregroundStyle(Palette.amber)
                .help("Memory grew noticeably over the last few minutes. This is an observation, not proof of a problem.")
        case .falling:
            Label("Shrinking", systemImage: "arrow.down.right").foregroundStyle(Palette.emerald)
        case .steady:
            Label("Steady", systemImage: "arrow.right").foregroundStyle(.secondary)
        case .unknown:
            Label("Watching", systemImage: "ellipsis").foregroundStyle(.tertiary)
                .help("Needs a few more samples before showing a trend")
        }
    }
}

struct MemoryAppIcon: View {
    let appPath: String?
    var size: CGFloat = 22

    var body: some View {
        if let appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size * 0.55))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}

struct MemoryOverview: View {
    let snapshot: SystemMemorySnapshot
    @Binding var tab: MemoryTab
    @EnvironmentObject private var memory: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Memory", subtitle: "What is using memory, and whether it is actually a problem.")
                pressureCard
                HStack(alignment: .top, spacing: 18) {
                    chartCard
                    breakdownCard.frame(width: 340)
                }
                topAppsCard
                footer
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private var pressureCard: some View {
        let state = memory.pressure
        return HStack(alignment: .center, spacing: 18) {
            Image(systemName: state.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 60, height: 60)
                .background(Circle().fill(state.color.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Memory pressure").font(.callout).foregroundStyle(.secondary)
                    InfoButton(text: "Pressure shows whether macOS is struggling to find memory. A Mac can use most of its memory and still be fine. macOS keeps memory busy on purpose, for example as file cache.")
                }
                Text(state.title).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(state.color)
                Text(state.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let since = memory.pressureSince, state != .unknown {
                    Text("Since \(since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                stat("Installed", MemoryFormat.bytes(snapshot.physicalMemoryBytes))
                stat("In use", MemoryFormat.bytes(snapshot.memoryUsedBytes))
                stat("Swap used", MemoryFormat.bytes(snapshot.swapUsedBytes))
            }
        }
        .card(padding: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory pressure \(state.title). \(state.explanation)")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private var chartCard: some View {
        let points = memory.history.system
        let gb = 1_073_741_824.0
        let maxGB = Double(snapshot.physicalMemoryBytes) / gb
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 5 minutes").font(.headline)
                Spacer()
                HStack(spacing: 12) {
                    legend(Palette.blue, "In use")
                    legend(Palette.amber, "Swap")
                }
                .font(.caption)
            }
            if points.count < 2 {
                Text("Collecting samples…").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        if let used = p.usedBytes {
                            AreaMark(x: .value("Time", p.time), y: .value("GB", Double(used) / gb), series: .value("Series", "In use"))
                                .foregroundStyle(LinearGradient(colors: [Palette.blue.opacity(0.25), Palette.blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Time", p.time), y: .value("GB", Double(used) / gb), series: .value("Series", "In use"))
                                .foregroundStyle(Palette.blue)
                        }
                        if let swap = p.swapUsedBytes {
                            LineMark(x: .value("Time", p.time), y: .value("GB", Double(swap) / gb), series: .value("Series", "Swap"))
                                .foregroundStyle(Palette.amber)
                        }
                    }
                }
                .chartYScale(domain: 0...maxGB)
                .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) GB") } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .minute)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 170)
                .accessibilityLabel("Memory in use and swap over the last 5 minutes")
                pressureStrip(points)
            }
        }
        .card(padding: 20)
    }

    private func pressureStrip(_ points: [SystemMemoryPoint]) -> some View {
        HStack(spacing: 6) {
            Text("Pressure").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(p.pressure.color)
                            .frame(width: geo.size.width / CGFloat(max(points.count, 1)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
        }
        .accessibilityHidden(true)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var breakdownCard: some View {
        let parts: [(String, Int64?, Color, String)] = [
            ("App memory", snapshot.appMemoryBytes, Palette.blue, "Memory used by apps and their processes."),
            ("Wired", snapshot.wiredMemoryBytes, Palette.coral, "Memory macOS itself needs. It cannot be compressed or moved to disk."),
            ("Compressed", snapshot.compressedMemoryBytes, Palette.amber, "Memory macOS squeezed to make room. This is normal."),
            ("Cached files", snapshot.cachedFilesBytes, Palette.teal, "Recently used files kept in memory for speed. macOS gives this back when apps need it."),
            ("Free", snapshot.freeBytes, Palette.slate, "Memory not used for anything right now. Low free memory is normal on a Mac.")
        ]
        let total = Double(max(snapshot.physicalMemoryBytes, 1))
        return VStack(alignment: .leading, spacing: 12) {
            Text("How memory is used").font(.headline)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        if let v = part.1, v > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(part.2)
                                .frame(width: max(3, geo.size.width * Double(v) / total))
                        }
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(part.2).frame(width: 10, height: 10)
                        Text(part.0).font(.callout)
                        InfoButton(text: part.3)
                        Spacer()
                        Text(MemoryFormat.bytes(part.1)).font(.callout.weight(.medium)).monospacedDigit()
                    }
                }
            }
            if snapshot.vmStatus != .available {
                Text("Some numbers are unavailable right now.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
    }

    private var topAppsCard: some View {
        let top = Array(memory.groups.prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Using the most memory").font(.headline)
                Spacer()
                Button("See all") { tab = .apps }.buttonStyle(.link)
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
                    MemorySparkline(points: group.recent, trend: group.trend)
                        .frame(width: 130, height: 28)
                    TrendBadge(trend: group.trend).font(.caption).labelStyle(.titleOnly)
                        .frame(width: 70, alignment: .leading)
                    Text(MemoryFormat.bytes(group.footprintBytes)).font(.callout.weight(.semibold)).monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 2)
                }
            }
            if memory.pressure == .normal {
                Text("Shown for context. With normal pressure, there is no need to close anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Group {
                if let c = memory.coverage {
                    Text("Updated \(snapshot.timestamp.formatted(date: .omitted, time: .standard)). Showing \(c.readableProcesses) of \(c.totalProcesses) processes. macOS system processes are hidden from apps, so their memory is not listed.")
                } else {
                    Text("Updated \(snapshot.timestamp.formatted(date: .omitted, time: .standard)).")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MemorySparkline: View {
    let points: [MemoryHistory.Point]
    let trend: MemoryTrend

    private var color: Color {
        switch trend {
        case .rising: return Palette.amber
        case .falling: return Palette.emerald
        default: return Palette.blue
        }
    }

    var body: some View {
        if points.count < 2 {
            Capsule().fill(Color.primary.opacity(0.06)).frame(height: 2)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
        } else {
            let values = points.map { Double($0.bytes) }
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let pad = max((high - low) * 0.15, high * 0.02, 1)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("Time", p.time), yStart: .value("Low", low - pad), yEnd: .value("Bytes", Double(p.bytes)))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.time), y: .value("Bytes", Double(p.bytes)))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .accessibilityHidden(true)
        }
    }
}

struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("More info")
        .popover(isPresented: $shown) {
            Text(text).font(.callout).padding(12).frame(width: 260).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MemoryAppsList: View {
    @Binding var tab: MemoryTab
    @EnvironmentObject private var memory: SystemMonitor
    @State private var search = ""
    @State private var grouped = true
    @State private var filter: MemoryGroupKind?
    @State private var sortOrder = [KeyPathComparator(\MemoryRow.bytes, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Memory", subtitle: "Apps and processes, biggest first.")
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find an app or process", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .frame(maxWidth: 300)
                Picker("Show", selection: $filter) {
                    Text("Everything").tag(MemoryGroupKind?.none)
                    Text("Apps").tag(MemoryGroupKind?.some(.app))
                    Text("Background").tag(MemoryGroupKind?.some(.backgroundApp))
                    Text("Processes").tag(MemoryGroupKind?.some(.process))
                }
                .fixedSize()
                Spacer()
                Toggle("Group by app", isOn: $grouped).toggleStyle(.switch).controlSize(.small)
            }
            table
            if let c = memory.coverage {
                Text("Memory footprint is the memory a process is responsible for, the same number Activity Monitor shows. Showing \(c.readableProcesses) of \(c.totalProcesses) processes; macOS system processes are hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var rows: [MemoryRow] {
        let total = memory.snapshot?.physicalMemoryBytes ?? 1
        var result: [MemoryRow]
        if grouped {
            result = memory.groups.map { g in
                MemoryRow(id: g.id, name: g.name, appPath: g.appPath, kind: g.kind, bytes: g.footprintBytes, total: total, trend: g.trend, detail: g.processes.count > 1 ? "\(g.processes.count) processes" : "PID \(g.processes[0].identity.pid)")
            }
        } else {
            let kinds = Dictionary(uniqueKeysWithValues: memory.groups.flatMap { g in g.processes.map { ($0.identity, (g.kind, g.appPath)) } })
            result = memory.processes.map { r in
                let k = kinds[r.sample.identity]
                return MemoryRow(id: "\(r.sample.identity.pid)-\(r.sample.identity.startTime)", name: r.sample.name, appPath: k?.1, kind: k?.0 ?? .process, bytes: r.sample.footprintBytes, total: total, trend: r.trend, detail: "PID \(r.sample.identity.pid)")
            }
        }
        if let filter { result = result.filter { $0.kind == filter } }
        if !search.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        return result.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 8) {
                    MemoryAppIcon(appPath: row.appPath, size: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name).lineLimit(1)
                        Text("\(row.kind.rawValue) · \(row.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 180)
            TableColumn("Memory footprint", value: \.bytes) { row in
                Text(MemoryFormat.bytes(row.bytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(130)
            TableColumn("% of memory", value: \.bytes) { row in
                Text(MemoryFormat.percent(row.bytes, of: row.total)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(100)
            TableColumn("Recent change", value: \.trendRank) { row in
                TrendBadge(trend: row.trend).font(.callout)
            }
            .width(120)
        }
    }
}

struct MemoryRow: Identifiable {
    let id: String
    let name: String
    let appPath: String?
    let kind: MemoryGroupKind
    let bytes: Int64
    let total: Int64
    let trend: MemoryTrend
    let detail: String

    var trendRank: Int {
        switch trend {
        case .rising: return 3
        case .steady: return 2
        case .falling: return 1
        case .unknown: return 0
        }
    }
}
