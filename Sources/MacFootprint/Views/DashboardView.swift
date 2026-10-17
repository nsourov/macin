import FootprintCore
import SwiftUI

private struct HealthCheck: Identifiable {
    enum Level { case good, notice, bad }
    let id: String
    let level: Level
    let title: String
    let symbol: String

    var color: Color {
        switch level {
        case .good: return Palette.emerald
        case .notice: return Palette.amber
        case .bad: return Palette.coral
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var memory: SystemMonitor
    @EnvironmentObject private var apps: ApplicationsModel
    @EnvironmentObject private var battery: BatteryModel
    @EnvironmentObject private var network: NetworkModel
    @StateObject private var system = LiveSystem()
    @State private var confirmTrash = false
    @State private var trashDone: TrashEmptyResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header.appear(0)
                healthCard.appear(1)
                modules.appear(2)
                suggestionsCard.appear(3)
                sectionTitle("Details")
                    .appear(4)
                if let scan = model.scan {
                    SpaceBreakdownCard(totals: scan.categoryTotals, checked: scan.totalAllocated, scan: scan).appear(4)
                } else if let last = model.sessions.first, !model.lastCategoryTotals.isEmpty {
                    SpaceBreakdownCard(totals: model.lastCategoryTotals, checked: last.scannedAllocated, scan: nil).appear(4)
                }
                HStack(alignment: .top, spacing: 18) {
                    memoryUsersCard
                    growthCard
                }
                .appear(5)
            }
            .padding(28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            model.refreshVolume()
            model.refreshTrashSize()
            apps.loadIfNeeded()
            system.start()
            memory.start()
        }
        .onDisappear {
            system.stop()
            memory.stop()
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmTrash) {
            Button("Empty Trash (\(ByteFormatter.string(model.trashBytes)))", role: .destructive) {
                Task { trashDone = await model.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash will be deleted for good, not only what Macin moved. You can't undo this.")
        }
        .alert("Trash emptied", isPresented: Binding(get: { trashDone != nil }, set: { if !$0 { trashDone = nil } })) {
            Button("OK") { trashDone = nil }
        } message: {
            if let trashDone {
                Text(trashDone.failedCount == 0
                     ? "Freed \(ByteFormatter.string(trashDone.removedBytes))."
                     : "Freed \(ByteFormatter.string(trashDone.removedBytes)). \(trashDone.failedCount) item(s) could not be removed. Try emptying them from Finder.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greetingText).font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Here is how your Mac is doing.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                Text("\(system.snapshot.chip) · \(system.snapshot.osVersion) · on for \(system.uptimeText)").lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.semibold)).padding(.top, 4)
    }

    private var checks: [HealthCheck] {
        var list: [HealthCheck] = []
        switch memory.pressure {
        case .normal, .unknown: list.append(HealthCheck(id: "memory", level: .good, title: "Memory is fine", symbol: "memorychip"))
        case .warning: list.append(HealthCheck(id: "memory", level: .notice, title: "Memory is tight", symbol: "memorychip"))
        case .critical: list.append(HealthCheck(id: "memory", level: .bad, title: "Memory is too full", symbol: "memorychip"))
        }
        if let v = model.volume {
            let free = Double(v.availableImportantBytes) / Double(max(v.totalBytes, 1))
            let level: HealthCheck.Level = free < 0.05 ? .bad : (free < 0.12 ? .notice : .good)
            list.append(HealthCheck(id: "disk", level: level, title: level == .good ? "Plenty of disk space" : "Disk space is low", symbol: "internaldrive"))
        }
        if memory.thermal.isElevated {
            list.append(HealthCheck(id: "cpu", level: memory.thermal == .critical ? .bad : .notice, title: "Mac is running hot", symbol: "thermometer.high"))
        } else if memory.observations.contains(where: { if case .thermal = $0.kind { return false }; return true }) {
            list.append(HealthCheck(id: "cpu", level: .notice, title: "Processor has stayed busy", symbol: "cpu"))
        } else {
            list.append(HealthCheck(id: "cpu", level: .good, title: "Processor is relaxed", symbol: "cpu"))
        }
        list.append(HealthCheck(id: "uptime", level: system.uptimeDays >= 7 ? .notice : .good,
                                title: system.uptimeDays >= 7 ? "On for \(system.uptimeDays) days" : "Restarted recently",
                                symbol: "clock.arrow.circlepath"))
        return list
    }

    private var overall: (title: String, note: String, color: Color, symbol: String) {
        let c = checks
        if c.contains(where: { $0.level == .bad }) {
            return ("Your Mac needs attention", "Something is close to its limit. See the suggestions below.", Palette.coral, "exclamationmark.triangle.fill")
        }
        let notices = c.filter { $0.level == .notice }.count
        if notices > 0 {
            return ("Mostly good", notices == 1 ? "One small thing to look at." : "\(notices) small things to look at.", Palette.amber, "hand.thumbsup.fill")
        }
        return ("Your Mac is in great shape", "Memory, disk and processor all look healthy.", Palette.emerald, "checkmark.seal.fill")
    }

    private var healthCard: some View {
        let c = checks
        let good = c.filter { $0.level == .good }.count
        let o = overall
        return HStack(spacing: 26) {
            HealthRing(fraction: Double(good) / Double(max(c.count, 1)), color: o.color, label: "\(good)/\(c.count)")
                .frame(width: 110, height: 110)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(o.title, systemImage: o.symbol)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(o.color)
                    Text(o.note).font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(c) { check in
                        HStack(spacing: 6) {
                            Image(systemName: check.level == .good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(check.color)
                            Text(check.title).font(.callout).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }

    private var modules: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
            storageModule
            memoryModule
            processorModule
            applicationsModule
            if battery.snapshot.hasBattery { batteryModule }
            networkModule
        }
    }

    private var batteryModule: some View {
        let b = battery.snapshot
        return ModuleCard(title: "Battery", symbol: "battery.75percent", color: Palette.emerald, badge: (b.stateTitle, b.color), action: { model.selection = .battery }) {
            HStack(spacing: 14) {
                BatteryGlyph(percent: b.chargePercent, color: b.color, charging: b.state == .charging)
                    .frame(width: 150, height: 74).scaleEffect(0.42).frame(width: 64, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.chargePercent.map { "\($0)%" } ?? "–").font(.title2.bold()).monospacedDigit().numeric()
                    Text(b.timeText ?? (b.source == .external ? "on power adapter" : "estimating…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let f = battery.finding, f.level == .worthReviewing {
                Label("Draining faster than usual", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.medium)).foregroundStyle(Palette.amber)
            } else {
                Text("On battery today: \(BatteryFormat.hours(battery.timeOnBatteryToday))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var networkModule: some View {
        let p = network.path
        let f = network.finding
        let badge: (String, Color)? = f.map { ($0.level == .good ? "Online" : ($0.level == .unknown ? (p.status == .available ? "Connected" : "Offline") : ($0.level == .warning ? "Partly" : "Problem")), $0.level == .unknown && p.status == .available ? Palette.blue : $0.level.color) }
        return ModuleCard(title: "Network", symbol: "network", color: Palette.blue, badge: badge, action: { model.selection = .network }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.status == .available ? (p.primary?.rawValue ?? "Connected") : "No connection").font(.title2.bold())
                Text(network.wifi.map { "signal \($0.quality.lowercased())\($0.rssi.map { " · \($0) dBm" } ?? "")" } ?? (p.status == .available ? "connected" : "check Wi-Fi or cable"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let last = network.lastRun, let r = network.latestResults.first(where: \.passed) {
                Text("Last check \(last.relative) · \(NetFormat.ms(r.totalDuration))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Run a check to test real websites").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageModule: some View {
        ModuleCard(title: "Storage", symbol: "internaldrive.fill", color: Palette.teal, action: { model.storageTab = .overview; model.selection = .candidates }) {
            if let v = model.volume {
                HStack(spacing: 14) {
                    DiskRing(volume: v).frame(width: 150, height: 150).scaleEffect(0.48).frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ByteFormatter.string(v.availableImportantBytes)).font(.title2.bold()).monospacedDigit().numeric()
                        Text("free of \(ByteFormatter.string(v.totalBytes))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.isScanning {
                HStack(spacing: 6) {
                    SpinningRing(lineWidth: 2).frame(width: 12, height: 12)
                    Text("Checking your Mac…").font(.caption.weight(.medium))
                }
                .foregroundStyle(Palette.sky)
            } else if model.scan == nil {
                if let last = model.sessions.first {
                    Text("Last scan \(last.startedAt.relative) · scan again to find clutter").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Scan to see what is using space").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.planSummary.totalBytes > 0 {
                Label("\(ByteFormatter.string(model.planSummary.totalBytes)) can be freed", systemImage: "leaf.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Palette.emerald)
            } else {
                Label("Nothing to clean", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Palette.emerald)
            }
        }
    }

    private var memoryModule: some View {
        let s = memory.snapshot
        let used = s?.memoryUsedBytes ?? 0
        let total = s?.physicalMemoryBytes ?? 1
        let state = memory.pressure
        return ModuleCard(title: "Memory", symbol: "memorychip.fill", color: Palette.blue, badge: state == .unknown ? nil : (state.title, state.color), action: { model.selection = .memory }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MemoryFormat.bytes(s?.memoryUsedBytes)).font(.title2.bold()).monospacedDigit()
                Text("in use of \(MemoryFormat.bytes(total))").font(.caption).foregroundStyle(.secondary)
            }
            MemorySparkline(points: memory.history.system.compactMap { p in p.usedBytes.map { MemoryHistory.Point(time: p.time, bytes: $0) } }, trend: .steady)
                .frame(height: 28)
            ProportionBar(fraction: Double(used) / Double(max(total, 1)), color: state == .unknown ? Palette.blue : state.color, animated: false)
        }
    }

    private var processorModule: some View {
        let cpu = memory.cpuUsage ?? 0
        let busy = !memory.observations.isEmpty
        let badge: (String, Color) = memory.thermal.isElevated ? (memory.thermal.title, memory.thermal.color) : (busy ? ("Busy", Palette.amber) : ("Relaxed", Palette.emerald))
        return ModuleCard(title: "Performance", symbol: "gauge.with.needle.fill", color: Palette.amber, badge: badge, action: { model.selection = .performance }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CPUFormat.percent(memory.cpuUsage)).font(.title2.bold()).monospacedDigit().numeric()
                Text("processor busy · heat \(TempFormat.heat(memory.thermal, memory.temperature).lowercased())").font(.caption).foregroundStyle(.secondary)
            }
            MemorySparkline(points: memory.cpuHistory.map { MemoryHistory.Point(time: $0.time, bytes: Int64($0.value * 1000)) }, trend: .steady)
                .frame(height: 28)
            ProportionBar(fraction: cpu, color: cpu > 0.85 ? Palette.coral : (cpu > 0.5 ? Palette.amber : Palette.emerald), animated: false)
        }
    }

    private var applicationsModule: some View {
        let biggest = apps.apps.compactMap { app in apps.sizes[app.path].map { (app, $0) } }.max { $0.1 < $1.1 }
        return ModuleCard(title: "Applications", symbol: "square.grid.2x2.fill", color: Palette.sky, badge: apps.runningCount > 0 ? ("\(apps.runningCount) running", Palette.emerald) : nil, action: { model.selection = .applications }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(apps.apps.isEmpty ? "–" : "\(apps.apps.count) apps").font(.title2.bold()).monospacedDigit().numeric()
                Text(apps.isMeasuring ? "measuring sizes…" : "using \(ByteFormatter.string(apps.totalBytes))").font(.caption).foregroundStyle(.secondary)
            }
            if let biggest {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: biggest.0.path)).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Biggest: \(biggest.0.name)").font(.caption.weight(.medium)).lineLimit(1)
                        Text(ByteFormatter.string(biggest.1)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1)
        }
        .font(.caption)
    }

    private struct Suggestion: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let title: String
        let detail: String
        let button: String?
        let action: (() -> Void)?
    }

    private var suggestions: [Suggestion] {
        var list: [Suggestion] = []
        if let obs = memory.visibleObservations.first {
            list.append(Suggestion(id: "perf", symbol: obs.symbol, color: obs.color, title: obs.title, detail: obs.detail,
                                   button: "See Performance", action: { model.selection = .performance }))
        }
        if memory.pressure == .warning || memory.pressure == .critical, let top = memory.groups.first {
            list.append(Suggestion(id: "memory", symbol: "memorychip", color: memory.pressure.color,
                                   title: "Memory is under pressure",
                                   detail: "\(top.name) is using \(MemoryFormat.bytes(top.footprintBytes)). Closing an app you don't need can help.",
                                   button: "See Memory", action: { model.selection = .memory }))
        }
        if model.planSummary.totalBytes >= 500_000_000 {
            list.append(Suggestion(id: "clean", symbol: "leaf.fill", color: Palette.emerald,
                                   title: "Free \(ByteFormatter.string(model.planSummary.totalBytes)) of safe clutter",
                                   detail: "We picked \(model.planSummary.items.count) item(s) that are safe to remove.",
                                   button: "Review", action: { model.storageTab = .cleanUp; model.selection = .candidates }))
        }
        if model.trashBytes >= 50_000_000 {
            list.append(Suggestion(id: "trash", symbol: "trash.fill", color: Palette.amber,
                                   title: "Your Trash holds \(ByteFormatter.string(model.trashBytes))",
                                   detail: "This space is not free until you empty the Trash.",
                                   button: model.isEmptyingTrash ? nil : "Empty…", action: { confirmTrash = true }))
        }
        if !model.isScanning {
            if let last = model.sessions.first?.startedAt ?? model.scan?.finishedAt {
                if Date().timeIntervalSince(last) > 7 * 86_400 {
                    list.append(Suggestion(id: "scan", symbol: "magnifyingglass", color: Palette.sky,
                                           title: "Your last scan was \(last.relative)",
                                           detail: "Scan again to find new clutter.",
                                           button: "Scan", action: { model.startScan() }))
                }
            } else {
                list.append(Suggestion(id: "scan", symbol: "magnifyingglass", color: Palette.sky,
                                       title: "Scan your Mac",
                                       detail: "See what is using space and what is safe to clean.",
                                       button: "Scan", action: { model.startScan() }))
            }
        }
        if system.uptimeDays >= 7 {
            list.append(Suggestion(id: "restart", symbol: "arrow.clockwise", color: Palette.slate,
                                   title: "Your Mac has been on for \(system.uptimeDays) days",
                                   detail: "A restart clears temporary files and can make things feel faster.",
                                   button: nil, action: nil))
        }
        return list
    }

    private var suggestionsCard: some View {
        let list = suggestions
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Suggestions").font(.headline)
                Spacer()
                if !list.isEmpty {
                    Text("\(list.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            if list.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Palette.emerald)
                    Text("Nothing to do right now. Enjoy your Mac.").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.color)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(item.color.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.medium))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let button = item.button, let action = item.action {
                        Button(button, action: action)
                    } else if item.id == "trash" && model.isEmptyingTrash {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .card(padding: 20)
    }

    private var memoryUsersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top memory users").font(.headline)
                Spacer()
                Button("See all") { model.selection = .memory }.buttonStyle(.link).font(.callout)
            }
            if memory.groups.isEmpty {
                Text("Reading memory…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(memory.groups.prefix(4)) { group in
                AppRowButton(appPath: group.appPath) {
                HStack(spacing: 8) {
                    MemoryAppIcon(appPath: group.appPath, size: 18)
                    Text(group.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 6)
                    MemorySparkline(points: group.recent, trend: group.trend)
                        .frame(width: 60, height: 16)
                    Text(MemoryFormat.bytes(group.footprintBytes))
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 20)
    }

    @ViewBuilder
    private var growthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Grew since last scan").font(.headline)
            if let cmp = model.latestComparison {
                let growers = Array(cmp.directoryDeltas.filter { $0.delta > 0 }.prefix(4))
                if growers.isEmpty {
                    Text("Nothing grew much. Nice!").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(growers) { d in
                    Button {
                        model.reveal(d.path)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.right").foregroundStyle(Palette.amber)
                            Text(URL(fileURLWithPath: d.path).lastPathComponent).lineLimit(1)
                            Spacer()
                            Text(ByteFormatter.signed(d.delta)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                        .hoverHighlight()
                    }
                    .buttonStyle(PressableStyle())
                    .help(d.path)
                }
            } else {
                Text("Scan a second time to see what grew.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 20)
    }
}

private struct ModuleCard<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    var badge: (String, Color)? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge.0)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(badge.1)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(badge.1.opacity(0.14)))
                    }
                    if action != nil {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                content
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .card(padding: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(action == nil)
    }
}

private struct HealthRing: View {
    let fraction: Double
    let color: Color
    let label: String
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: 12)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(label).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                Text("good").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : Motion.gentle.delay(0.15)) { shown = fraction } }
        .onChange(of: fraction) { _, value in withAnimation(Motion.spring) { shown = value } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) checks good")
    }
}

struct StackedBar: View {
    let data: [(StorageCategory, Int64)]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let total = Double(max(data.reduce(0) { $0 + $1.1 }, 1))
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(data, id: \.0) { item in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(item.0.color)
                        .frame(width: max(4, (geo.size.width - CGFloat(data.count) * 3) * Double(item.1) / total))
                        .help("\(item.0.title): \(ByteFormatter.string(item.1))")
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .mask(alignment: .leading) {
                Rectangle().frame(width: shown ? geo.size.width : 0)
            }
        }
        .clipShape(Capsule())
        .onAppear {
            withAnimation(reduceMotion ? nil : Motion.gentle.delay(0.2)) { shown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage by type")
    }
}

struct DiskRing: View {
    let volume: VolumeInfo
    @State private var progress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var used: Double { Double(volume.usedBytes) / Double(max(volume.totalBytes, 1)) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [Palette.teal, Palette.sky, Palette.blue, Palette.teal], center: .center),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit().numeric()
                Text("used").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : Motion.gentle.delay(0.15)) { progress = used }
        }
        .onChange(of: used) { _, newValue in
            withAnimation(Motion.spring) { progress = newValue }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk \(Int(used * 100)) percent used")
    }
}

extension View {
    func softPill(_ color: Color) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.12)))
    }
}
