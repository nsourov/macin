import AppKit
import FootprintCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct ScanCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Scan Now") { model.startScan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanning)
            Button("Cancel Scan") { model.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isScanning)
        }
    }
}

@main
struct MacFootprintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppSettings.Keys.menuBar) private var showMenuBar = true
    private let settings: AppSettings
    private let model: AppModel
    private let memory: SystemMonitor
    private let apps: ApplicationsModel
    private let scheduler: ScheduledCleaner
    private let battery: BatteryModel
    private let network: NetworkModel

    init() {
        let settings = AppSettings()
        self.settings = settings
        settings.applyAppearance()
        self.model = AppModel(settings: settings)
        self.memory = SystemMonitor()
        self.apps = ApplicationsModel()
        self.scheduler = ScheduledCleaner(model: model, settings: settings)
        let metrics = MetricsStore()
        self.battery = BatteryModel(store: metrics, monitor: memory)
        self.network = NetworkModel(store: metrics)
        memory.start()
        scheduler.start()
        battery.start()
        network.start()
    }

    var body: some Scene {
        Window("Macin", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(memory)
                .environmentObject(apps)
                .environmentObject(settings)
                .environmentObject(scheduler)
                .environmentObject(battery)
                .environmentObject(network)
                .frame(minWidth: 820, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands { ScanCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(settings)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(memory)
                .environmentObject(apps)
                .environmentObject(settings)
                .environmentObject(battery)
                .environmentObject(network)
        } label: {
            TrayLabel(memory: memory)
        }
        .menuBarExtraStyle(.window)
    }
}
