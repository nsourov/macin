import Charts
import FootprintCore
import SwiftUI

enum NetworkTab: String, ModuleTab {
    case overview = "Overview"
    case check = "Check"
    case history = "History"
    case sites = "Test Sites"

    var title: String { rawValue }
}

enum NetFormat {
    static func ms(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "–" }
        return "\(max(1, Int((seconds * 1000).rounded()))) ms"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        if bits >= 1_000_000 { return String(format: "%.1f Mbps", bits / 1_000_000) }
        if bits >= 1_000 { return String(format: "%.0f Kbps", bits / 1_000) }
        return "\(Int(bits)) bps"
    }
}

extension StageState {
    var symbol: String {
        switch self {
        case .queued: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .timedOut: return "clock.badge.exclamationmark.fill"
        case .skipped: return "minus.circle"
        case .unsupported: return "nosign"
        }
    }

    var color: Color {
        switch self {
        case .passed: return Palette.emerald
        case .failed: return Palette.coral
        case .timedOut: return Palette.amber
        case .running: return Palette.blue
        default: return Palette.slate
        }
    }

    var title: String {
        switch self {
        case .queued: return "Waiting"
        case .running: return "Checking…"
        case .passed: return "OK"
        case .failed: return "Failed"
        case .timedOut: return "Timed out"
        case .skipped: return "Skipped"
        case .unsupported: return "Not tested"
        }
    }
}

extension NetworkFinding.Level {
    var color: Color {
        switch self {
        case .good: return Palette.emerald
        case .warning: return Palette.amber
        case .problem: return Palette.coral
        case .unknown: return Palette.slate
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

extension InterfaceKind {
    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        default: return "network"
        }
    }
}

struct NetworkView: View {
    @EnvironmentObject private var network: NetworkModel
    @State private var tab: NetworkTab = .overview

    var body: some View {
        Group {
            switch tab {
            case .overview: NetworkOverview(tab: $tab)
            case .check: NetworkCheck()
            case .history: NetworkHistory()
            case .sites: NetworkSites()
            }
        }
        .moduleTabs($tab)
        .onAppear { network.watch() }
        .onDisappear { network.unwatch() }
    }
}

struct ConsentCard: View {
    @EnvironmentObject private var network: NetworkModel
    var onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Palette.blue)
                Text("Allow connection checks?").font(.headline)
            }
            Text("To test your Internet, Macin opens these small web pages. It does not read your browsing, capture traffic or send personal data.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(network.enabledDestinations) { d in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(d.name) · \(d.host ?? d.url)").font(.callout.weight(.medium))
                        Text(d.disclosure).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Change Test Sites") { onManage() }
                Spacer()
                Button("Allow Checks") { network.consented = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Palette.blue.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Palette.blue.opacity(0.22)))
    }
}

struct NetworkOverview: View {
    @Binding var tab: NetworkTab
    @EnvironmentObject private var network: NetworkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Network", subtitle: "Whether your connection works, and where it breaks if it doesn't.")
                if !network.consented { ConsentCard { tab = .sites } }
                statusCard
                HStack(alignment: .top, spacing: 18) {
                    trafficCard.frame(maxWidth: .infinity)
                    VStack(spacing: 18) {
                        if network.path.interfaces.contains(.wifi) { wifiCard }
                        pathCard
                    }
                    .frame(width: 330)
                }
                if !network.latestResults.isEmpty { latestCard }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private var statusCard: some View {
        let path = network.path
        let finding = network.finding ?? NetworkDiagnosis.evaluate(path: path, results: [])
        let connected = path.status == .available
        return HStack(spacing: 20) {
            ZStack {
                Circle().fill(finding.level.color.opacity(0.14))
                Image(systemName: connected ? (path.primary?.symbol ?? "network") : "wifi.slash")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(finding.level.color)
            }
            .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: 5) {
                Text(connected ? "Connected via \(path.primary?.rawValue ?? "network")" : "No connection")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Text(finding.title).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(finding.level.color)
                Text(finding.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let change = network.lastChange {
                        Text("Changed \(change.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let last = network.lastRun {
                        Text(network.isFresh ? "Checked \(last.formatted(.relative(presentation: .named)))" : "Last check is old · \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button {
                    tab = .check
                    network.runDiagnostics()
                } label: {
                    Label(network.isRunning ? "Checking…" : "Run Check", systemImage: "stethoscope").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!network.consented || network.isRunning)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    private var trafficCard: some View {
        let points = network.rates
        let last = points.last
        let peak = points.map { max($0.down, $0.up) * 8 }.max() ?? 0
        let scale: Double = peak >= 1_000_000 ? 1_000_000 : 1_000
        let unit = scale == 1_000_000 ? "Mb" : "Kb"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Traffic right now").font(.headline)
                InfoButton(text: "All data your Mac is sending and receiving over Wi-Fi and Ethernet right now. This is not a speed test and is not split by app.")
                Spacer()
            }
            HStack(spacing: 18) {
                rateTile("arrow.down", Palette.blue, "Download", last?.down)
                rateTile("arrow.up", Palette.chartPeach, "Upload", last?.up)
            }
            if points.count < 2 {
                Text("Collecting…").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(points) { p in
                    AreaMark(x: .value("Time", p.time), y: .value("Rate", p.down * 8 / scale), series: .value("Dir", "Down"))
                        .foregroundStyle(Palette.blue.opacity(0.2))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.time), y: .value("Rate", p.down * 8 / scale), series: .value("Dir", "Down"))
                        .foregroundStyle(Palette.blue)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.time), y: .value("Rate", p.up * 8 / scale), series: .value("Dir", "Up"))
                        .foregroundStyle(Palette.chartPeach)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f \(unit)", d)) } } } }
                .frame(height: 150)
            }
        }
        .card(padding: 20)
    }

    private func rateTile(_ symbol: String, _ color: Color, _ title: String, _ value: Double?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(color)
                .frame(width: 24, height: 24).background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value.map(NetFormat.rate) ?? "–").font(.title3.weight(.semibold)).monospacedDigit().numeric()
            }
        }
    }

    private var wifiCard: some View {
        let w = network.wifi
        let bars = w?.rssi.map { $0 >= -55 ? 4 : ($0 >= -67 ? 3 : ($0 >= -75 ? 2 : 1)) } ?? 0
        let color: Color = bars >= 3 ? Palette.emerald : (bars == 2 ? Palette.amber : Palette.coral)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wi-Fi").font(.headline)
                Spacer()
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(1...4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5).fill(i <= bars ? color : Color.primary.opacity(0.12))
                            .frame(width: 5, height: CGFloat(4 + i * 3))
                    }
                }
                Text(w?.quality ?? "Unknown").font(.callout.weight(.semibold)).foregroundStyle(color)
            }
            kv("Signal", w?.rssi.map { "\($0) dBm" } ?? "Not available")
            kv("Noise", w?.noise.map { "\($0) dBm" } ?? "Not available")
            kv("Channel", w?.channel.map { "\($0)\(w?.band.map { " · \($0)" } ?? "")" } ?? "Not available")
            kv("Link speed", w?.txRate.map { "\(Int($0)) Mbps" } ?? "Not available")
        }
        .card(padding: 18)
    }

    private var pathCard: some View {
        let p = network.path
        return VStack(alignment: .leading, spacing: 10) {
            Text("Connection details").font(.headline)
            kv("IPv4", flag(p.supportsIPv4))
            kv("IPv6", flag(p.supportsIPv6))
            kv("DNS", flag(p.supportsDNS))
            kv("Costly network", flag(p.isExpensive), info: "macOS marks networks like phone hotspots as costly.")
            kv("Low Data Mode", flag(p.isConstrained))
        }
        .card(padding: 18)
    }

    private var latestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last check").font(.headline)
                Spacer()
                Button("Details") { tab = .check }.buttonStyle(.link)
            }
            ForEach(network.latestResults) { r in
                HStack(spacing: 10) {
                    Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.passed ? Palette.emerald : Palette.coral)
                    Text(r.endpointName).font(.callout.weight(.medium)).frame(width: 110, alignment: .leading)
                    StageBar(result: r)
                    Text(r.passed ? NetFormat.ms(r.totalDuration) : (r.firstFailure?.kind.rawValue ?? "Failed"))
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .frame(width: 130, alignment: .trailing)
                }
            }
        }
        .card(padding: 20)
    }

    private func kv(_ k: String, _ v: String, info: String? = nil) -> some View {
        HStack {
            Text(k).font(.callout).foregroundStyle(.secondary)
            if let info { InfoButton(text: info) }
            Spacer()
            Text(v).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    private func flag(_ v: Bool?) -> String {
        guard let v else { return "Not reported" }
        return v ? "Yes" : "No"
    }
}

struct StageBar: View {
    let result: EndpointTestResult

    var body: some View {
        let parts: [(StageKind, Color)] = [(.dns, Palette.sky), (.connect, Palette.blue), (.tls, Palette.chartPeach), (.http, Palette.emerald)]
        let values = parts.map { (result.stage($0.0)?.duration ?? 0, $0.1) }
        let total = max(values.reduce(0) { $0 + $1.0 }, 0.001)
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    Rectangle().fill(v.1).frame(width: max(0, geo.size.width * v.0 / total))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("Light blue: name lookup · Blue: connect · Peach: secure connection · Green: web response")
    }
}

struct NetworkCheck: View {
    @EnvironmentObject private var network: NetworkModel
    @State private var latencyTarget: UUID?
    @State private var showExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Connection Check", subtitle: "Tests each step in order, so you can see where it breaks.") {
                    HStack(spacing: 8) {
                        Button { showExport = true } label: { Label("Export Report…", systemImage: "square.and.arrow.up") }
                            .disabled(network.latestResults.isEmpty)
                        if network.isRunning {
                            Button("Cancel") { network.cancel() }
                        } else {
                            Button { network.runDiagnostics() } label: { Label("Run Check", systemImage: "stethoscope") }
                                .buttonStyle(.borderedProminent)
                                .disabled(!network.consented)
                        }
                    }
                }
                if !network.consented { ConsentCard {} }
                if let f = network.finding { findingCard(f) }
                let shown = network.isRunning ? Array(network.live.values).sorted { $0.endpointName < $1.endpointName } : network.latestResults
                if shown.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "stethoscope").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("Run a check to test your connection step by step.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .card(padding: 20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(shown) { r in resultCard(r) }
                    }
                }
                latencyCard
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showExport) { NetworkExportSheet().environmentObject(network) }
    }

    private func findingCard(_ f: NetworkFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: f.level.symbol).font(.title2).foregroundStyle(f.level.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title).font(.headline)
                    Text(f.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !f.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHAT WAS TESTED").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(f.evidence, id: \.self) { Text("• \($0)").font(.caption) }
                }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HOW SURE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(f.confidence).font(.callout)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("WHAT YOU CAN DO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(f.nextStep).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(padding: 18)
    }

    private func resultCard(_ r: EndpointTestResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(r.endpointName).font(.headline)
                Text(r.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let total = r.totalDuration, r.passed { Text(NetFormat.ms(total)).font(.callout.weight(.semibold)).monospacedDigit() }
            }
            ForEach(r.stages, id: \.kind) { s in
                HStack(spacing: 8) {
                    Image(systemName: s.state.symbol)
                        .foregroundStyle(s.state.color)
                        .symbolEffect(.pulse, isActive: s.state == .running)
                        .frame(width: 18)
                    Text(s.kind.rawValue).font(.callout)
                    Spacer()
                    if let d = s.duration, s.state == .passed { Text(NetFormat.ms(d)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    Text(s.state.title).font(.caption.weight(.medium)).foregroundStyle(s.state.color)
                }
                .help(s.detail ?? "")
                if let detail = s.detail, s.state == .failed || s.state == .timedOut {
                    Text(detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                }
            }
        }
        .card(padding: 16)
    }

    private var latencyCard: some View {
        let options = network.enabledDestinations
        let target = options.first { $0.id == latencyTarget } ?? options.first
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Response time").font(.headline)
                InfoButton(text: "Connects 5 times, 1 second apart, and measures how long each connection takes. It is not a download speed test and only shows how fast this one site answers.")
                Spacer()
                Picker("Site", selection: Binding(get: { target?.id }, set: { latencyTarget = $0 })) {
                    ForEach(options) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                Button(network.latencyRunning ? "Testing \(network.latencyProgress)/5…" : "Test 5 Times") {
                    if let target { network.measureLatency(target) }
                }
                .disabled(network.latencyRunning || target == nil || !network.consented)
            }
            if let stats = network.latency {
                HStack(spacing: 12) {
                    statTile("Typical", NetFormat.ms(stats.median), Palette.blue)
                    statTile("Fastest", NetFormat.ms(stats.minimum), Palette.emerald)
                    statTile("Slowest", NetFormat.ms(stats.maximum), Palette.amber)
                    statTile("Jitter", NetFormat.ms(stats.jitter), Palette.slate)
                    statTile("Failed", "\(stats.failures)", stats.failures > 0 ? Palette.coral : Palette.slate)
                }
                if !stats.samples.isEmpty {
                    Chart(Array(stats.samples.enumerated()), id: \.offset) { i, v in
                        BarMark(x: .value("Try", "#\(i + 1)"), y: .value("ms", v * 1000))
                            .foregroundStyle(Palette.blue.gradient)
                            .cornerRadius(4)
                    }
                    .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) ms") } } } }
                    .frame(height: 120)
                }
            } else {
                Text("Pick a site and test it to see how quickly it answers.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
    }

    private func statTile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct NetworkExportSheet: View {
    @EnvironmentObject private var network: NetworkModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeSystem = false
    @State private var includeHosts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export network report").font(.title2.bold())
            Text("Check what goes into the report. It is saved only where you choose.").font(.callout).foregroundStyle(.secondary)
            Toggle("Include macOS version", isOn: $includeSystem)
            Toggle("Include test site addresses", isOn: $includeHosts)
            Text("Never included: network names, hardware and IP addresses, DNS servers, browsing activity.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(network.report(includeSystem: includeSystem, includeHosts: includeHosts))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save…") {
                    network.export(includeSystem: includeSystem, includeHosts: includeHosts)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 600, height: 560)
    }
}

struct NetworkHistory: View {
    @EnvironmentObject private var network: NetworkModel
    @State private var endpoint: UUID?

    var body: some View {
        let names = Dictionary(grouping: network.results, by: \.endpointID)
        let options = names.keys.compactMap { id in names[id]?.first.map { (id, $0.endpointName) } }.sorted { $0.1 < $1.1 }
        let selected = endpoint ?? options.first?.0
        let rows = network.results.filter { selected == nil || $0.endpointID == selected }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Network History", subtitle: "Your checks and connection changes from the last 7 days.")
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Check results").font(.headline)
                        Spacer()
                        if !options.isEmpty {
                            Picker("Site", selection: Binding(get: { selected }, set: { endpoint = $0 })) {
                                ForEach(options, id: \.0) { Text($0.1).tag(Optional($0.0)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    if rows.isEmpty {
                        Text("No checks yet.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        Chart {
                            ForEach(rows.filter(\.passed)) { r in
                                PointMark(x: .value("Time", r.startedAt), y: .value("ms", (r.totalDuration ?? 0) * 1000))
                                    .foregroundStyle(Palette.blue)
                                    .symbolSize(40)
                            }
                            ForEach(rows.filter { !$0.passed }) { r in
                                RuleMark(x: .value("Time", r.startedAt))
                                    .foregroundStyle(Palette.coral.opacity(0.6))
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) ms") } } } }
                        .frame(height: 200)
                        HStack(spacing: 14) {
                            Label("Total time when it worked", systemImage: "circle.fill").foregroundStyle(Palette.blue)
                            Label("Failed check", systemImage: "line.diagonal").foregroundStyle(Palette.coral)
                        }
                        .font(.caption)
                    }
                }
                .card(padding: 20)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Timeline").font(.headline)
                    let timeline = timelineItems
                    if timeline.isEmpty {
                        Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(timeline.prefix(50), id: \.0) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.2).foregroundStyle(item.3).frame(width: 22)
                            Text(item.1).font(.callout)
                            Spacer()
                            Text(item.0.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .card(padding: 20)
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private var timelineItems: [(Date, String, String, Color)] {
        var items: [(Date, String, String, Color)] = network.events.map { e in
            e.status == .available
                ? (e.time, "Connected\(e.interface.map { " via \($0.rawValue)" } ?? "")", e.interface?.symbol ?? "network", Palette.emerald)
                : (e.time, "Connection \(e.status.rawValue)", "wifi.slash", Palette.coral)
        }
        let runs = Dictionary(grouping: network.results) { Int($0.startedAt.timeIntervalSince1970 / 60) }
        for (_, group) in runs {
            guard let first = group.first else { continue }
            let failed = group.filter { !$0.passed }.count
            items.append((first.startedAt,
                          failed == 0 ? "Check passed (\(group.count) site\(group.count == 1 ? "" : "s"))" : "Check: \(failed) of \(group.count) failed",
                          "stethoscope", failed == 0 ? Palette.blue : Palette.amber))
        }
        return items.sorted { $0.0 > $1.0 }
    }
}

struct NetworkSites: View {
    @EnvironmentObject private var network: NetworkModel
    @State private var name = ""
    @State private var url = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Test Sites", subtitle: "Choose which sites Macin contacts when it checks your connection.")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($network.destinations) { $d in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(d.name, isOn: $d.enabled).toggleStyle(.switch).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(d.name).font(.callout.weight(.medium))
                                    Text(d.isBuiltIn ? "Built in" : "Yours")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                                }
                                Text(d.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if !d.disclosure.isEmpty { Text(d.disclosure).font(.caption).foregroundStyle(.tertiary) }
                            }
                            Spacer()
                            Button("Test Now") { network.runDiagnostics(only: d) }
                                .disabled(!network.consented || network.isRunning)
                                .controlSize(.small)
                            if !d.isBuiltIn {
                                Button { network.remove(d) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Remove")
                            }
                        }
                        Divider()
                    }
                    HStack(spacing: 8) {
                        TextField("Name", text: $name).frame(width: 140)
                        TextField("https://example.com/health", text: $url)
                        Button("Add") {
                            error = network.addDestination(name: name, url: url)
                            if error == nil { name = ""; url = "" }
                        }
                        .disabled(url.isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                    if let error { Text(error).font(.caption).foregroundStyle(Palette.coral) }
                    HStack {
                        Text("Each check makes one small web request per site, waits at most 5 seconds and reads at most 64 KB.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore Defaults") { network.restoreDefaults() }.controlSize(.small)
                    }
                }
                .card(padding: 20)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Options").font(.headline)
                    row("Allow connection checks", "Macin only contacts the sites above, and only when a check runs.", $network.consented)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Check automatically").font(.callout.weight(.medium))
                            Text("Runs a quick check in the background while Macin is open.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Check automatically", selection: $network.autoCheck) {
                            ForEach(AutoCheck.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!network.consented)
                    }
                    Divider()
                    row("Tell me when the connection drops or returns", "One notice per change. Quick flickers are ignored.", $network.changeAlerts)
                    Divider()
                    HStack {
                        Text("History is kept for 7 days on this Mac only.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete History…", systemImage: "trash") }
                    }
                }
                .card(padding: 20)
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Delete network history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive) { network.deleteHistory() }
        } message: {
            Text("This removes Macin's saved checks and connection changes only.")
        }
    }

    private func row(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}
