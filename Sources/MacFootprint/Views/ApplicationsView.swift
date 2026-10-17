import FootprintCore
import SwiftUI

enum AppFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case large = "Large"
    case yours = "Yours"
    case macOS = "macOS"

    var id: String { rawValue }
}

enum AppSort: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"

    var id: String { rawValue }
}

struct ApplicationsView: View {
    @EnvironmentObject private var apps: ApplicationsModel
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var settings: AppSettings
    @State private var search = ""
    @State private var filter: AppFilter = .all
    @State private var sort: AppSort = .size
    @State private var selected: InstalledApp?

    private static let largeBytes: Int64 = 1_000_000_000

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Applications", subtitle: "Apps on this Mac, how much space they use, and the data they keep.") {
                    Button { apps.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(apps.isLoading)
                }
                if apps.apps.isEmpty && apps.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding apps…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    summaryCard
                    tools
                    listCard
                    coverageNote
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            apps.loadIfNeeded()
            apps.refreshRunning()
        }
        .sheet(item: $selected) { app in
            AppDetailSheet(app: app)
                .environmentObject(apps)
                .environmentObject(monitor)
                .environmentObject(settings)
        }
    }

    private var biggest: [(InstalledApp, Int64)] {
        apps.apps.compactMap { app in apps.sizes[app.path].map { (app, $0) } }
            .sorted { $0.1 > $1.1 }
    }

    private var summaryCard: some View {
        let top = Array(biggest.prefix(6))
        let total = apps.totalBytes
        let colors = [Palette.chartBlue, Palette.chartTeal, Palette.chartPeach, Palette.chartRose, Palette.chartGreen, Palette.chartYellow]
        let rest = max(total - top.reduce(0) { $0 + $1.1 }, 0)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                tile("square.grid.2x2.fill", Palette.blue, "\(apps.apps.count)", "apps found")
                tile("internaldrive.fill", Palette.teal, ByteFormatter.string(total), apps.isMeasuring ? "measuring \(apps.sizingRemaining) more…" : "used by apps")
                tile("play.circle.fill", Palette.emerald, "\(apps.runningCount)", "running now")
            }
            if !top.isEmpty && total > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Biggest apps").font(.headline)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(top.enumerated()), id: \.element.0.id) { i, item in
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(colors[i % colors.count])
                                    .frame(width: max(3, geo.size.width * Double(item.1) / Double(total)))
                                    .help("\(item.0.name): \(ByteFormatter.string(item.1))")
                            }
                            if rest > 0 {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.chartGray.opacity(0.5))
                                    .frame(width: max(3, geo.size.width * Double(rest) / Double(total)))
                            }
                        }
                    }
                    .frame(height: 12)
                    .clipShape(Capsule())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], alignment: .leading, spacing: 8) {
                        ForEach(Array(top.enumerated()), id: \.element.0.id) { i, item in
                            Button { selected = item.0 } label: {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(colors[i % colors.count]).frame(width: 10, height: 10)
                                    Text(item.0.name).font(.callout).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(ByteFormatter.string(item.1)).font(.callout.weight(.medium)).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
        }
        .card(padding: 20)
    }

    private func tile(_ symbol: String, _ color: Color, _ value: String, _ caption: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.bold()).monospacedDigit().numeric()
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var tools: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an app", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .frame(maxWidth: 260)
            Picker("Show", selection: $filter) {
                ForEach(AppFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(AppSort.allCases) { Text("By \($0.rawValue.lowercased())").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var visible: [InstalledApp] {
        var list = apps.apps
        switch filter {
        case .all: break
        case .running: list = list.filter { apps.running.contains($0.path) }
        case .large: list = list.filter { (apps.sizes[$0.path] ?? 0) >= Self.largeBytes }
        case .yours: list = list.filter { !$0.isProtected && !$0.isApple }
        case .macOS: list = list.filter { $0.isProtected || $0.isApple }
        }
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        switch sort {
        case .size: list.sort { (apps.sizes[$0.path] ?? -1) > (apps.sizes[$1.path] ?? -1) }
        case .name: break
        }
        return list
    }

    private var listCard: some View {
        let list = visible
        let largest = Double(max(biggest.first?.1 ?? 1, 1))
        return VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                Text(search.isEmpty ? "No apps here." : "Nothing matches “\(search)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider().padding(.leading, 44) }
                Button { selected = app } label: {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                                if apps.running.contains(app.path) {
                                    Circle().fill(Palette.emerald).frame(width: 6, height: 6)
                                        .help("Running")
                                }
                                if app.isProtected {
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                                        .help("Part of macOS")
                                }
                            }
                            Text([app.version.map { "Version \($0)" }, app.location.rawValue].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let size = apps.sizes[app.path] {
                            ProportionBar(fraction: Double(size) / largest, color: Palette.teal, animated: false)
                                .frame(width: 110)
                            Text(ByteFormatter.string(size)).font(.callout.weight(.semibold)).monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        } else {
                            ProgressView().controlSize(.small).frame(width: 196, alignment: .trailing)
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .hoverHighlight()
                }
                .buttonStyle(PressableStyle())
            }
        }
        .card(padding: 16)
    }

    private var coverageNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Looked in \(apps.scannedRoots.map(PathTools.display).joined(separator: ", "))\(apps.skippedRoots.isEmpty ? "" : ". Could not read \(apps.skippedRoots.map(PathTools.display).joined(separator: ", "))"). Apps saved in other folders are not listed. Sizes are space on disk.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AppRowButton<Label: View>: View {
    let appPath: String?
    @ViewBuilder var label: Label
    @EnvironmentObject private var apps: ApplicationsModel
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var settings: AppSettings
    @State private var app: InstalledApp?

    var body: some View {
        if let appPath {
            Button { app = apps.app(forPath: appPath) } label: {
                label.contentShape(Rectangle()).hoverHighlight()
            }
            .buttonStyle(PressableStyle())
            .help("See details")
            .sheet(item: $app) { app in
                AppDetailSheet(app: app)
                    .environmentObject(apps)
                    .environmentObject(monitor)
            }
        } else {
            label
        }
    }
}

struct AppDetailSheet: View {
    let app: InstalledApp
    @EnvironmentObject private var apps: ApplicationsModel
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var related: [RelatedItem]?
    @State private var uninstalling = false

    private var live: MemoryGroup? { monitor.groups.first { $0.appPath == app.path } }
    private var canUninstall: Bool { !app.isProtected && apps.uninstaller(mode: .trash).blockReason(for: app, checkRunning: false) == nil }

    var body: some View {
        Group {
            if uninstalling, let related {
                UninstallView(app: app, related: related, onCancel: { withAnimation(Motion.smooth) { uninstalling = false } }, onFinish: { dismiss() })
                    .transition(.opacity)
            } else {
                details.transition(.opacity)
            }
        }
        .frame(width: 660, height: 680)
        .task {
            await apps.measureIfNeeded(app)
            related = await apps.relatedItems(for: app)
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let live { liveCard(live) }
                    spaceCard
                    relatedCard
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title2.bold())
                Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                HStack(spacing: 6) {
                    if live != nil || apps.running.contains(app.path) {
                        badge("Running", Palette.emerald)
                    }
                    if app.isProtected { badge("Part of macOS", Palette.slate) }
                    badge(app.location.rawValue, Palette.sky)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                HStack(spacing: 8) {
                    Button { apps.open(app) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    Button { apps.reveal(app.path) } label: { Label("Show in Finder", systemImage: "folder") }
                    if canUninstall {
                        Button(role: .destructive) {
                            withAnimation(Motion.smooth) { uninstalling = true }
                        } label: {
                            Label("Uninstall…", systemImage: "trash").foregroundStyle(Palette.coral)
                        }
                        .disabled(related == nil)
                        .help(related == nil ? "Looking for this app's data first" : "Remove this app and pick which of its data to remove")
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(20)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func liveCard(_ group: MemoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Right now").font(.headline)
                Spacer()
                Text(group.processes.count > 1 ? "\(group.processes.count) processes" : "1 process").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                liveTile("memorychip", Palette.blue, "Memory", MemoryFormat.bytes(group.footprintBytes),
                         MemorySparkline(points: group.recent, trend: group.trend))
                liveTile("cpu", Palette.amber, "Processor", CPUFormat.percent(group.cpu),
                         MemorySparkline(points: group.cpuRecent.map { MemoryHistory.Point(time: $0.time, bytes: Int64($0.value * 1000)) }, trend: .steady))
                liveTile("bolt", Palette.emerald, "Energy", group.power.map(BatteryFormat.watts) ?? "–",
                         MemorySparkline(points: group.powerRecent.map { MemoryHistory.Point(time: $0.time, bytes: Int64($0.value * 1000)) }, trend: .steady),
                         caption: group.energyJoules > 0 ? "\(BatteryFormat.energy(group.energyJoules)) since opened" : nil)
                    .help("Energy measured by macOS. The big number is the average of the last minute.")
            }
        }
        .card(padding: 18)
    }

    private func liveTile(_ symbol: String, _ color: Color, _ title: String, _ value: String, _ chart: MemorySparkline, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Text(value).font(.title3.bold()).monospacedDigit()
            chart.frame(height: 30)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var spaceCard: some View {
        let bundle = apps.sizes[app.path]
        let data = related?.reduce(0) { $0 + $1.bytes }
        let total = Double(max((bundle ?? 0) + (data ?? 0), 1))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Space used").font(.headline)
            HStack(spacing: 12) {
                spaceTile(Palette.teal, "The app", bundle)
                spaceTile(Palette.chartPeach, "Its data", data)
            }
            if let bundle, let data, bundle + data > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Rectangle().fill(Palette.teal).frame(width: max(3, geo.size.width * Double(bundle) / total))
                        Rectangle().fill(Palette.chartPeach).frame(width: max(data > 0 ? 3 : 0, geo.size.width * Double(data) / total))
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
            }
            Text("The app and its data are counted apart. Sizes are estimates of space on disk.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 18)
    }

    private func spaceTile(_ color: Color, _ title: String, _ bytes: Int64?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 10, height: 10)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if let bytes {
                Text(ByteFormatter.string(bytes)).font(.callout.weight(.semibold)).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var relatedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Data this app keeps").font(.headline)
                InfoButton(text: "Files in your Library folder that belong to this app. “Sure” means the folder is named exactly after the app's ID. “Maybe” only shares the name, so it could belong to something else.")
                Spacer()
            }
            if let related {
                if related.isEmpty {
                    Label("No data found for this app in your Library folder.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach([AssociationConfidence.high, .medium, .low], id: \.self) { level in
                    let items = related.filter { $0.confidence == level }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(sectionTitle(level)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(items) { item in relatedRow(item) }
                        }
                    }
                }
                if related.contains(where: { $0.risk == .userData }) {
                    Label("Containers and shared folders may hold your documents. Macin will never pick them for you.", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for this app's data…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .card(padding: 18)
    }

    private func sectionTitle(_ level: AssociationConfidence) -> String {
        switch level {
        case .high: return "SURE — NAMED AFTER THE APP"
        case .medium: return "LIKELY"
        case .low: return "MAYBE — SAME NAME ONLY"
        }
    }

    private func relatedRow(_ item: RelatedItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(item.category))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(riskColor(item.risk))
                .frame(width: 28, height: 28)
                .background(Circle().fill(riskColor(item.risk).opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.category.rawValue).font(.callout.weight(.medium))
                    Text(item.risk.rawValue).font(.caption).foregroundStyle(riskColor(item.risk))
                }
                Text(PathTools.display(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteFormatter.string(item.bytes)).font(.callout.weight(.medium)).monospacedDigit()
            Button { apps.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .help(item.evidence)
    }

    private func symbol(_ category: RelatedCategory) -> String {
        switch category {
        case .caches: return "shippingbox"
        case .logs: return "doc.text"
        case .savedState: return "macwindow"
        case .preferences: return "slider.horizontal.3"
        case .support: return "folder"
        case .webData: return "globe"
        case .containers: return "archivebox"
        case .groupContainers: return "person.2"
        case .launchAgents: return "power"
        }
    }

    private func riskColor(_ risk: RelatedRisk) -> Color {
        switch risk {
        case .regenerable: return Palette.emerald
        case .persistent: return Palette.amber
        case .preferences: return Palette.sky
        case .userData: return Palette.coral
        }
    }
}
