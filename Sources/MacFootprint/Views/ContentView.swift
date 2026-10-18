import FootprintCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showOnboarding = false

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.selection },
            set: { newValue in
                if let newValue, newValue != model.selection { model.selection = newValue }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                row(.dashboard)
                row(.assistant)
                Section("Your Mac") {
                    row(.candidates)
                    row(.memory)
                    row(.performance)
                    row(.applications)
                    if BatteryModel.hasBattery { row(.battery) }
                    row(.network)
                }
                Section("App") {
                    row(.settings)
                }
            }
            .safeAreaInset(edge: .bottom) { SidebarDiskMeter() }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 200)
        } detail: {
            VStack(spacing: 0) {
                if model.scan != nil && model.isScanning {
                    ScanStatusBar().transition(.slideDown)
                }
                ZStack {
                    detail
                        .id(model.selection ?? .dashboard)
                        .transition(.pageSwap)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .animation(Motion.smooth, value: model.selection)
            .animation(Motion.spring, value: model.isScanning)
            .animation(Motion.smooth, value: model.scan?.id)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            if model.selection == .dashboard || model.selection == .candidates || model.selection == nil {
                ToolbarItem(placement: .primaryAction) {
                    if model.isScanning {
                        Button { model.cancelScan() } label: { Label("Cancel Scan", systemImage: "stop.circle") }
                            .help("Cancel scan")
                    } else {
                        Button { model.startScan() } label: { Label("Scan Now", systemImage: "arrow.clockwise") }
                            .help("Scan now (⌘R)")
                    }
                }
            }
        }
        .task {
            guard !settings.hasOnboarded else { return }
            try? await Task.sleep(for: .milliseconds(400))
            showOnboarding = true
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environmentObject(model)
                .environmentObject(settings)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(badge(for: item))
            .help(item.hint)
            .tag(item)
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .candidates: return model.planIDs.count
        default: return 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .assistant: AssistantView()
        case .candidates: StorageView()
        case .memory: MemoryView()
        case .performance: PerformanceView()
        case .applications: ApplicationsView()
        case .battery: BatteryView()
        case .network: NetworkView()
        case .settings: SettingsPage()
        }
    }
}

struct SidebarDiskMeter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let v = model.volume {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text(v.name).font(.caption.weight(.semibold)).lineLimit(1)
                }
                ProportionBar(fraction: Double(v.usedBytes) / Double(max(v.totalBytes, 1)), color: usageColor(v))
                Text("\(ByteFormatter.string(v.availableImportantBytes)) available")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(10)
            .accessibilityElement(children: .combine)
        }
    }

    private func usageColor(_ v: VolumeInfo) -> Color {
        let used = Double(v.usedBytes) / Double(max(v.totalBytes, 1))
        return used > 0.9 ? Palette.amber : Palette.teal
    }
}
