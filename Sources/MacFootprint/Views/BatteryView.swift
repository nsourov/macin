import Charts
import FootprintCore
import SwiftUI

enum BatteryTab: String, ModuleTab {
    case overview = "Overview"
    case history = "History"
    case settings = "Settings"

    var title: String { rawValue }
}

extension BatterySnapshot {
    var stateTitle: String {
        switch state {
        case .charging: return "Charging"
        case .discharging: return "On battery"
        case .charged: return "Fully charged"
        case .pluggedNotCharging: return "Plugged in, not charging"
        case .unknown: return "Unknown"
        }
    }

    var stateSymbol: String {
        switch state {
        case .charging: return "bolt.fill"
        case .charged, .pluggedNotCharging: return "powerplug.fill"
        case .discharging: return "battery.75percent"
        case .unknown: return "questionmark"
        }
    }

    var color: Color {
        guard let p = chargePercent else { return Palette.slate }
        if state == .charging || state == .charged { return Palette.emerald }
        if p <= 10 { return Palette.coral }
        if p <= 20 { return Palette.amber }
        return Palette.emerald
    }

    var timeText: String? {
        if let m = minutesToEmpty { return "\(BatteryFormat.duration(m)) left" }
        if let m = minutesToFull { return "\(BatteryFormat.duration(m)) until full" }
        return nil
    }

    var conditionTitle: String? {
        guard let condition else { return nil }
        switch condition.lowercased() {
        case "good": return "Normal"
        case "fair": return "Fair"
        case "poor", "check battery": return "Service recommended"
        default: return condition
        }
    }
}

enum BatteryFormat {
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func hours(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    static func watts(_ value: Double) -> String {
        value < 0.1 ? String(format: "%.0f mW", value * 1000) : String(format: "%.1f W", value)
    }

    static func energy(_ joules: Double) -> String {
        let wh = joules / 3600
        return wh < 1 ? String(format: "%.0f mWh", wh * 1000) : String(format: "%.1f Wh", wh)
    }
}

struct BatteryView: View {
    @EnvironmentObject private var battery: BatteryModel
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var tab: BatteryTab = .overview

    var body: some View {
        Group {
            if !battery.snapshot.hasBattery {
                ContentUnavailableView("Battery information isn't available on this Mac",
                                       systemImage: "powerplug",
                                       description: Text("This Mac runs on wall power, so there is no battery to show. Memory, Performance and Network still work."))
            } else {
                switch tab {
                case .overview: BatteryOverview(tab: $tab)
                case .history: BatteryHistory()
                case .settings: BatterySettings()
                }
            }
        }
        .moduleTabs($tab)
        .onAppear {
            battery.watch()
            monitor.start()
        }
        .onDisappear {
            battery.unwatch()
            monitor.stop()
        }
    }
}

struct BatteryGlyph: View {
    let percent: Int?
    let color: Color
    let charging: Bool

    var body: some View {
        HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 3)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .frame(width: max(8, (geo.size.width - 12) * Double(percent ?? 0) / 100))
                        .padding(6)
                        .animation(Motion.smooth, value: percent)
                }
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .frame(maxWidth: .infinity)
                }
            }
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.25)).frame(width: 6, height: 26)
        }
    }
}

struct BatteryOverview: View {
    @Binding var tab: BatteryTab
    @EnvironmentObject private var battery: BatteryModel
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var showDetails = false

    var body: some View {
        let snap = battery.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Battery", subtitle: "Charge, charging and how your battery is used over time.")
                hero(snap)
                findingCard
                HStack(alignment: .top, spacing: 18) {
                    chartCard.frame(maxWidth: .infinity)
                    detailsCard(snap).frame(width: 320)
                }
                AppEnergyCard()
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private func hero(_ snap: BatterySnapshot) -> some View {
        HStack(spacing: 28) {
            BatteryGlyph(percent: snap.chargePercent, color: snap.color, charging: snap.state == .charging)
                .frame(width: 150, height: 74)
            VStack(alignment: .leading, spacing: 6) {
                Text(snap.chargePercent.map { "\($0)%" } ?? "–")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .numeric()
                Label(snap.stateTitle, systemImage: snap.stateSymbol)
                    .font(.headline)
                    .foregroundStyle(snap.color)
                Text(snap.timeText ?? (snap.state == .discharging || snap.state == .charging ? "Time estimate: not available yet" : "Running on power adapter"))
                    .font(.callout).foregroundStyle(.secondary)
                    .help("This estimate comes from macOS. It changes with what you are doing.")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                pill("Power", snap.source == .external ? "Power adapter" : (snap.source == .battery ? "Battery" : "Unknown"))
                pill("Low Power Mode", snap.lowPowerMode ? "On" : "Off")
                Text("Updated \(battery.lastRefresh.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    private func pill(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold))
        }
    }

    @ViewBuilder
    private var findingCard: some View {
        if let f = battery.finding {
            let color: Color = f.level == .worthReviewing ? Palette.amber : (f.level == .normal ? Palette.emerald : Palette.slate)
            let symbol = f.level == .worthReviewing ? "exclamationmark.triangle.fill" : (f.level == .normal ? "checkmark.circle.fill" : "clock")
            let title = f.level == .worthReviewing ? "Battery went down faster than usual" : (f.level == .normal ? "Battery use looks normal" : "Still learning your battery")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(color.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(f.observation).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(showDetails ? "Hide details" : "Why?") { withAnimation(Motion.snappy) { showDetails.toggle() } }
                        .buttonStyle(.link)
                }
                if showDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        detail("When", f.window)
                        detail("Context", f.context)
                        detail("How sure", f.confidence)
                        detail("What you can do", f.nextStep)
                        detail("Limits", f.limitations)
                    }
                    .padding(.leading, 54)
                    .transition(.opacity)
                }
                if f.level == .worthReviewing {
                    HStack {
                        Spacer()
                        Button("Open Performance") { model.selection = .performance }
                    }
                }
            }
            .card(padding: 18)
        }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chartCard: some View {
        let points = battery.samples(in: .day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last 24 hours").font(.headline)
                Spacer()
                Button("See history") { tab = .history }.buttonStyle(.link)
            }
            if points.count < 2 {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.tertiary)
                    Text("History starts now. Macin saves your charge level every 2 minutes while it is open.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                BatteryChart(samples: points, height: 170)
            }
        }
        .card(padding: 20)
    }

    private func detailsCard(_ snap: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery details").font(.headline)
            row("Condition", snap.conditionTitle ?? "Not available", info: "As reported by macOS. Apple shows more in System Settings → Battery.")
            Divider()
            row("On battery today", BatteryFormat.hours(battery.timeOnBatteryToday), info: "Only counts time while Macin was running.")
            Divider()
            row("Cycle count", "Not available", info: "macOS does not share this through a public interface, so Macin does not guess it.")
            Divider()
            row("Maximum capacity", "Not available", info: "macOS does not share this through a public interface, so Macin does not guess it.")
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open Battery Settings", systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .card(padding: 20)
    }

    private func row(_ title: String, _ value: String, info: String) -> some View {
        HStack {
            Text(title).font(.callout)
            InfoButton(text: info)
            Spacer()
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(value == "Not available" ? .secondary : .primary)
        }
    }
}

enum AppEnergyRange: String, CaseIterable, Identifiable {
    case now = "Right now"
    case sinceOpened = "Since apps opened"

    var id: String { rawValue }
}

struct AppEnergyCard: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @State private var range: AppEnergyRange = .now

    private func amount(_ group: MemoryGroup) -> Double {
        range == .now ? (group.power ?? 0) : group.energyJoules
    }

    private func label(_ group: MemoryGroup) -> String {
        range == .now ? BatteryFormat.watts(group.power ?? 0) : BatteryFormat.energy(group.energyJoules)
    }

    var body: some View {
        let ranked = monitor.groups.filter { amount($0) > 0 }.sorted { amount($0) > amount($1) }
        let total = ranked.reduce(0) { $0 + amount($1) }
        let top = Array(ranked.prefix(8))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apps using battery").font(.headline)
                InfoButton(text: "Energy each app used, as measured by macOS. \"Right now\" is the average of the last minute. \"Since apps opened\" counts from when each app started. Some system processes are hidden.")
                Spacer()
                Picker("", selection: $range) {
                    ForEach(AppEnergyRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            if top.isEmpty {
                Text("Measuring… this takes a few seconds.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(top) { group in
                let share = total > 0 ? amount(group) / total : 0
                AppRowButton(appPath: group.appPath) {
                    HStack(spacing: 10) {
                        MemoryAppIcon(appPath: group.appPath)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text("\(Int((share * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            ThinBar(fraction: share, color: share > 0.4 ? Palette.amber : Palette.emerald)
                        }
                        Text(label(group)).font(.callout.weight(.semibold)).monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .card(padding: 20)
    }
}

struct BatteryChart: View {
    let samples: [BatterySample]
    var height: CGFloat = 220

    private var segments: [(Int, BatterySample)] {
        var out: [(Int, BatterySample)] = []
        var segment = 0
        for (i, s) in samples.enumerated() {
            if i > 0, s.time.timeIntervalSince(samples[i - 1].time) > BatteryAnalysis.maxGap { segment += 1 }
            out.append((segment, s))
        }
        return out
    }

    var body: some View {
        let events = BatteryAnalysis.events(samples).filter { $0.kind != .gap }
        Chart {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, item in
                AreaMark(x: .value("Time", item.1.time), y: .value("Charge", item.1.percent), series: .value("Part", item.0))
                    .foregroundStyle(LinearGradient(colors: [Palette.emerald.opacity(0.25), Palette.emerald.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", item.1.time), y: .value("Charge", item.1.percent), series: .value("Part", item.0))
                    .foregroundStyle(Palette.emerald)
                    .interpolationMethod(.monotone)
            }
            ForEach(events) { e in
                RuleMark(x: .value("Time", e.time))
                    .foregroundStyle(e.kind == .pluggedIn ? Palette.blue.opacity(0.5) : Palette.amber.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Image(systemName: e.kind == .pluggedIn ? "powerplug.fill" : "battery.50percent")
                            .font(.caption2)
                            .foregroundStyle(e.kind == .pluggedIn ? Palette.blue : Palette.amber)
                    }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Int.self) { Text("\(d)%") } } } }
        .frame(height: height)
        .accessibilityLabel("Battery charge over time")
    }
}

struct BatteryHistory: View {
    @EnvironmentObject private var battery: BatteryModel
    @State private var range: BatteryRange = .day

    var body: some View {
        let points = battery.samples(in: range)
        let events = BatteryAnalysis.events(points).reversed()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Battery History", subtitle: "Real samples only. Gaps mean Macin was closed or the Mac was asleep.") {
                    Picker("Range", selection: $range) {
                        ForEach(BatteryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        legend(Palette.emerald, "Charge")
                        legend(Palette.blue, "Plugged in")
                        legend(Palette.amber, "Unplugged")
                        Spacer()
                        Text("\(points.count) samples").font(.caption).foregroundStyle(.secondary)
                    }
                    if points.count < 2 {
                        Text("Not enough history for this range yet.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        BatteryChart(samples: points, height: 260)
                    }
                }
                .card(padding: 20)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Timeline").font(.headline)
                    if events.isEmpty {
                        Text("No plug-in or unplug events in this range.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(events.prefix(40))) { e in
                        HStack(spacing: 10) {
                            Image(systemName: symbol(e.kind))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(color(e.kind))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(color(e.kind).opacity(0.14)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title(e)).font(.callout.weight(.medium))
                                Text(e.time.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
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

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(_ e: BatteryEvent) -> String {
        switch e.kind {
        case .pluggedIn: return "Plugged in at \(e.percent.map { "\($0)%" } ?? "–")"
        case .unplugged: return "Unplugged at \(e.percent.map { "\($0)%" } ?? "–")"
        case .gap: return "No data (Macin closed or Mac asleep)"
        }
    }

    private func symbol(_ k: BatteryEvent.Kind) -> String {
        switch k {
        case .pluggedIn: return "powerplug.fill"
        case .unplugged: return "battery.50percent"
        case .gap: return "moon.zzz"
        }
    }

    private func color(_ k: BatteryEvent.Kind) -> Color {
        switch k {
        case .pluggedIn: return Palette.blue
        case .unplugged: return Palette.amber
        case .gap: return Palette.slate
        }
    }
}

struct BatterySettings: View {
    @EnvironmentObject private var battery: BatteryModel
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Battery Settings", subtitle: "Choose what Macin saves and when it tells you.")
                VStack(alignment: .leading, spacing: 14) {
                    Text("Alerts").font(.headline)
                    toggle("Low battery alert", "Get one notice when charge drops to your level. It won't repeat until you charge.", $battery.lowAlertEnabled)
                    if battery.lowAlertEnabled {
                        Stepper("Alert at \(battery.lowThreshold)%", value: $battery.lowThreshold, in: 5...50, step: 5)
                            .font(.callout)
                    }
                    Divider()
                    toggle("Faster than usual drain", "Get a notice when the battery goes down much faster than normal. At most once every 2 hours.", $battery.drainAlertEnabled)
                }
                .card(padding: 20)

                VStack(alignment: .leading, spacing: 14) {
                    Text("History").font(.headline)
                    toggle("Save battery history", "Saves a small sample every 2 minutes while Macin is open. Kept for 30 days on this Mac only.", $battery.historyEnabled)
                    Text("Each sample has: time, charge %, on battery or plugged in, charging or not, and how busy the processor was. Nothing is uploaded.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button { battery.export() } label: { Label("Export CSV…", systemImage: "square.and.arrow.up") }
                            .disabled(battery.samples.isEmpty)
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete History…", systemImage: "trash") }
                            .disabled(battery.samples.isEmpty)
                    }
                }
                .card(padding: 20)
            }
            .padding(24)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Delete battery history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive) { battery.deleteHistory() }
        } message: {
            Text("This removes only Macin's saved battery samples. macOS logs are not touched.")
        }
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
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
