import AppKit
import FootprintCore
import SwiftUI
import UserNotifications

@MainActor
final class ScheduledCleaner: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var isRunning = false

    private let model: AppModel
    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        super.init()
    }

    func start() {
        guard loop == nil else { return }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                await self?.runIfDue()
            }
        }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.runIfDue()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func runIfDue() async {
        guard settings.cleanupFrequency.isDue(last: settings.lastScheduledCleanup) else { return }
        await run()
    }

    func runNow() {
        Task { await run() }
    }

    private func run() async {
        guard !isRunning, !model.isScanning, !model.isCleaning else { return }
        isRunning = true
        defer { isRunning = false }
        settings.lastScheduledCleanup = Date()

        model.startScan()
        while model.isScanning {
            try? await Task.sleep(for: .seconds(2))
        }
        guard model.scan != nil else { return }

        let items = model.scheduledItems
        let bytes = CleanupPlanner.summarize(items).totalBytes
        guard bytes >= ScheduledCleanupPolicy.minimumBytes else {
            settings.lastScheduledSummary = "Checked \(Date().formatted(date: .abbreviated, time: .shortened)). Nothing worth cleaning."
            return
        }

        switch settings.cleanupScheduleMode {
        case .ask:
            settings.lastScheduledSummary = "Found \(ByteFormatter.string(bytes)) to clean on \(Date().formatted(date: .abbreviated, time: .shortened)). Waiting for you."
            notify(title: "You can free \(ByteFormatter.string(bytes))",
                   body: "Macin found caches and build files that are safe to remove. Click to review.")
        case .automatic:
            guard let result = await model.execute(items, goal: nil, mode: .trash) else { return }
            let moved = result.movedEstimatedBytes
            settings.lastScheduledSummary = "Cleaned \(ByteFormatter.string(moved)) on \(Date().formatted(date: .abbreviated, time: .shortened)). Items are in the Trash."
            notify(title: "Macin cleaned \(ByteFormatter.string(moved))",
                   body: result.failed.isEmpty && result.skipped.isEmpty
                       ? "\(result.moved.count) item(s) moved to the Trash. You can put them back."
                       : "\(result.moved.count) item(s) moved to the Trash. Some items were kept. Click to see why.")
        }
    }

    private func notify(title: String, body: String) {
        Notifier.post(id: "scheduled-cleanup", title: title, body: body, target: nil)
    }

    private func open(_ target: SidebarItem?) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        if let target {
            model.selection = target
        } else {
            model.storageTab = .cleanUp
            model.selection = .candidates
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["target"] as? String
        await MainActor.run { open(raw.flatMap(SidebarItem.init(rawValue:))) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

enum Notifier {
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(id: String, title: String, body: String, target: SidebarItem?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let target { content.userInfo = ["target": target.rawValue] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
