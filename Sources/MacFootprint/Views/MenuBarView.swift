import AppKit
import FootprintCore
import SwiftUI

struct ThinBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(Motion.smooth, value: fraction)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var memory: SystemMonitor
    @EnvironmentObject private var battery: BatteryModel
    @EnvironmentObject private var network: NetworkModel
    @Environment(\.openWindow) private var openWindow
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                memoryTile
                processorTile
                storageTile
                if battery.snapshot.hasBattery { batteryTile } else { networkTile }
            }
            topApps
            if battery.snapshot.hasBattery { networkRow }
            if let note {
                Label(note.0, systemImage: note.1)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(note.2)
                    .lineLimit(2)
            }
            Divider()
            HStack {
                Button { open(nil) } label: { Label("Open Macin", systemImage: "macwindow") }
                Spacer()
                Button("Quit Macin") {
                    AppDelegate.allowQuit = true
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            visible = true
            memory.start()
            network.watch()
            model.refreshVolume()
        }
        .onDisappear {
            visible = false
            memory.stop()
            network.unwatch()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text("Macin").font(.headline)
            Spacer()
            let status = overall
            HStack(spacing: 4) {
                Circle().fill(status.1).frame(width: 6, height: 6)
                Text(status.0).font(.caption.weight(.semibold))
            }
            .foregroundStyle(status.1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(status.1.opacity(0.12)))
        }
    }

    private var overall: (String, Color) {
        if memory.pressure == .critical || memory.thermal == .critical { return ("Needs attention", Palette.coral) }
        if memory.pressure == .warning || memory.thermal.isElevated || !memory.visibleObservations.isEmpty { return ("Busy", Palette.amber) }
        return ("All good", Palette.emerald)
    }

    private var note: (String, String, Color)? {
        if let obs = memory.visibleObservations.first { return (obs.title, obs.symbol, obs.color) }
        if memory.pressure == .warning || memory.pressure == .critical { return (memory.pressure.explanation, memory.pressure.symbol, memory.pressure.color) }
        if model.planSummary.totalBytes > 0 { return ("You can free \(ByteFormatter.string(model.planSummary.totalBytes))", "leaf.fill", Palette.emerald) }
        return nil
    }

    private func tile<Content: View>(_ title: String, _ symbol: String, _ color: Color, target: SidebarItem, @ViewBuilder content: () -> Content) -> some View {
        Button { open(target) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Open \(title)")
    }

    private func value(_ text: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var memoryTile: some View {
        let s = memory.snapshot
        let used = Double(s?.memoryUsedBytes ?? 0)
        let total = Double(max(s?.physicalMemoryBytes ?? 1, 1))
        let color = memory.pressure == .unknown || memory.pressure == .normal ? Palette.blue : memory.pressure.color
        return tile("Memory", "memorychip", color, target: .memory) {
            value(MemoryFormat.bytes(s?.memoryUsedBytes), "of \(MemoryFormat.bytes(s?.physicalMemoryBytes))")
            Spacer(minLength: 0)
            ThinBar(fraction: used / total, color: color)
        }
    }

    private var processorTile: some View {
        let cpu = memory.cpuUsage ?? 0
        let color = cpu > 0.85 ? Palette.coral : (cpu > 0.5 ? Palette.amber : Palette.amber.opacity(0.85))
        return tile("Processor", "cpu", Palette.amber, target: .performance) {
            value(CPUFormat.percent(memory.cpuUsage), memory.temperature.chip.map { "busy · \(TempFormat.string($0))" } ?? "busy · heat \(memory.thermal.title.lowercased())")
            Spacer(minLength: 0)
            if visible && memory.cpuHistory.count > 1 {
                MemorySparkline(points: memory.cpuHistory.suffix(30).map { MemoryHistory.Point(time: $0.time, bytes: Int64($0.value * 1000)) }, trend: .steady)
                    .frame(height: 14)
            } else {
                ThinBar(fraction: cpu, color: color)
            }
        }
    }

    private var storageTile: some View {
        let v = model.volume
        let fraction = v.map { Double($0.usedBytes) / Double(max($0.totalBytes, 1)) } ?? 0
        return tile("Storage", "internaldrive", Palette.teal, target: .candidates) {
            value(v.map { ByteFormatter.string($0.availableImportantBytes) } ?? "–", "free of \(v.map { ByteFormatter.string($0.totalBytes) } ?? "–")")
            Spacer(minLength: 0)
            ThinBar(fraction: fraction, color: fraction > 0.9 ? Palette.amber : Palette.teal)
        }
    }

    private var batteryTile: some View {
        let b = battery.snapshot
        return tile("Battery", b.state == .charging ? "bolt.fill" : "battery.75percent", b.color, target: .battery) {
            value(b.chargePercent.map { "\($0)%" } ?? "–", b.timeText ?? b.stateTitle.lowercased())
            Spacer(minLength: 0)
            ThinBar(fraction: Double(b.chargePercent ?? 0) / 100, color: b.color)
        }
    }

    private var networkTile: some View {
        let p = network.path
        let ok = p.status == .available
        let down = network.rates.last?.down
        return tile("Network", ok ? (p.primary?.symbol ?? "network") : "wifi.slash", ok ? Palette.blue : Palette.coral, target: .network) {
            value(ok ? (p.primary?.rawValue ?? "Online") : "Offline", network.wifi.map { "signal \($0.quality.lowercased())" } ?? (ok ? "connected" : "no connection"))
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.blue)
                Text(down.map(NetFormat.rate) ?? "–").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var networkRow: some View {
        let p = network.path
        let ok = p.status == .available
        return Button { open(.network) } label: {
            HStack(spacing: 8) {
                Image(systemName: ok ? (p.primary?.symbol ?? "network") : "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ok ? Palette.blue : Palette.coral)
                    .frame(width: 16)
                Text(ok ? (p.primary?.rawValue ?? "Connected") : "No connection").font(.callout.weight(.medium))
                if let w = network.wifi, ok {
                    Text("signal \(w.quality.lowercased())").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let down = network.rates.last?.down {
                    Text("↓ \(NetFormat.rate(down))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Using the most memory").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button("See all") { open(.memory) }.buttonStyle(.link).font(.caption)
            }
            ForEach(memory.groups.prefix(3)) { group in
                HStack(spacing: 8) {
                    MemoryAppIcon(appPath: group.appPath, size: 16)
                    Text(group.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 6)
                    if visible {
                        MemorySparkline(points: group.recent, trend: group.trend)
                            .frame(width: 48, height: 12)
                    }
                    Text(MemoryFormat.bytes(group.footprintBytes))
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if let path = group.appPath { QuitMenuItems(appPath: path) }
                }
            }
            if memory.groups.isEmpty {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func open(_ item: SidebarItem?) {
        if let item {
            if item == .candidates { model.storageTab = .overview }
            model.selection = item
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
