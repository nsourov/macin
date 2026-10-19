import AppKit
import FootprintCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var allowQuit = false
    static var openMain: (() -> Void)?

    private var keepsRunning: Bool {
        UserDefaults.standard.object(forKey: AppSettings.Keys.menuBar) as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowOpened(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowClosed(_:)), name: NSWindow.willCloseNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(powerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard keepsRunning, !Self.allowQuit else { return .terminateNow }
        for window in NSApp.windows where isAppWindow(window) {
            window.close()
        }
        moveToMenuBar()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !NSApp.windows.contains(where: { $0.isVisible && isAppWindow($0) }), let openMain = Self.openMain {
            openMain()
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        return true
    }

    @objc private func powerOff() {
        Self.allowQuit = true
    }

    @objc private func windowOpened(_ note: Notification) {
        guard let window = note.object as? NSWindow, isAppWindow(window), NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowClosed(_ note: Notification) {
        guard let closing = note.object as? NSWindow, isAppWindow(closing), keepsRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && self.isAppWindow($0) }) {
                self.moveToMenuBar()
            }
        }
    }

    private func moveToMenuBar() {
        NSApp.setActivationPolicy(.accessory)
    }

    private func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.level == .normal && window.styleMask.contains(.titled) && window.canBecomeMain
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
    private let assistant: AssistantModel

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
        self.assistant = AssistantModel(model: model, monitor: memory, battery: battery, network: network, apps: apps)
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
                .environmentObject(assistant)
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
