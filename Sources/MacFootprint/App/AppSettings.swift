import AppKit
import Foundation
import FootprintCore
import ServiceManagement

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Keys.onboarded) } }
    @Published var scanRoots: [String] { didSet { save(scanRoots, Keys.scanRoots) } }
    @Published var developerRoots: [String] { didSet { save(developerRoots, Keys.devRoots) } }
    @Published var ignoredPaths: [String] { didSet { save(ignoredPaths, Keys.ignored) } }
    @Published var historyRetentionDays: Int { didSet { defaults.set(historyRetentionDays, forKey: Keys.retention) } }
    @Published var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: Keys.menuBar) } }
    @Published var includeAppContainers: Bool { didSet { defaults.set(includeAppContainers, forKey: Keys.containers) } }
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance); applyAppearance() } }
    @Published var deletePermanently: Bool { didSet { defaults.set(deletePermanently, forKey: Keys.deletePermanently) } }
    @Published var cleanupFrequency: CleanupFrequency {
        didSet {
            defaults.set(cleanupFrequency.rawValue, forKey: Keys.cleanupFrequency)
            if cleanupFrequency != oldValue { lastScheduledCleanup = Date() }
        }
    }
    @Published var cleanupScheduleMode: ScheduledCleanupMode { didSet { defaults.set(cleanupScheduleMode.rawValue, forKey: Keys.cleanupScheduleMode) } }
    @Published var lastScheduledCleanup: Date? { didSet { defaults.set(lastScheduledCleanup, forKey: Keys.lastScheduledCleanup) } }
    @Published var lastScheduledSummary: String? { didSet { defaults.set(lastScheduledSummary, forKey: Keys.lastScheduledSummary) } }
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: Keys.autoUpdate) } }
    @Published var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: Keys.lastUpdateCheck) } }
    @Published var launchAtLoginError: String?

    enum Keys {
        static let onboarded = "hasOnboarded"
        static let scanRoots = "scanRoots"
        static let devRoots = "developerRoots"
        static let ignored = "ignoredPaths"
        static let retention = "historyRetentionDays"
        static let menuBar = "showMenuBar"
        static let containers = "includeAppContainers"
        static let appearance = "appearance"
        static let deletePermanently = "deletePermanently"
        static let cleanupFrequency = "cleanupFrequency"
        static let cleanupScheduleMode = "cleanupScheduleMode"
        static let lastScheduledCleanup = "lastScheduledCleanup"
        static let lastScheduledSummary = "lastScheduledSummary"
        static let autoUpdate = "autoUpdate"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    static var standardRoots: [String] { [PathTools.home.path, "/Applications"] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        scanRoots = Self.load(defaults, Keys.scanRoots) ?? Self.standardRoots
        developerRoots = Self.load(defaults, Keys.devRoots) ?? []
        ignoredPaths = Self.load(defaults, Keys.ignored) ?? []
        historyRetentionDays = defaults.object(forKey: Keys.retention) as? Int ?? 90
        showMenuBar = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
        includeAppContainers = defaults.bool(forKey: Keys.containers)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .auto
        deletePermanently = defaults.bool(forKey: Keys.deletePermanently)
        cleanupFrequency = defaults.string(forKey: Keys.cleanupFrequency).flatMap(CleanupFrequency.init(rawValue:)) ?? .off
        cleanupScheduleMode = defaults.string(forKey: Keys.cleanupScheduleMode).flatMap(ScheduledCleanupMode.init(rawValue:)) ?? .ask
        lastScheduledCleanup = defaults.object(forKey: Keys.lastScheduledCleanup) as? Date
        lastScheduledSummary = defaults.string(forKey: Keys.lastScheduledSummary)
        autoUpdate = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        lastUpdateCheck = defaults.object(forKey: Keys.lastUpdateCheck) as? Date
    }

    var nextScheduledCleanup: Date? {
        cleanupFrequency.nextRun(after: lastScheduledCleanup ?? Date())
    }

    var removalMode: RemovalMode { deletePermanently ? .permanent : .trash }

    func applyAppearance() {
        switch appearance {
        case .auto: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private static func load(_ defaults: UserDefaults, _ key: String) -> [String]? {
        defaults.stringArray(forKey: key)
    }

    private func save(_ value: [String], _ key: String) {
        defaults.set(value, forKey: key)
    }

    var effectiveScanRoots: [URL] {
        let all = scanRoots + developerRoots
        return ScanRequest.normalizedRoots(all.map { URL(fileURLWithPath: $0) })
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "Could not change login item: \(error.localizedDescription). This works only when running the bundled app."
            }
            objectWillChange.send()
        }
    }

    func ignore(_ path: String) {
        guard !ignoredPaths.contains(path) else { return }
        ignoredPaths.append(path)
    }

    func unignore(_ path: String) {
        ignoredPaths.removeAll { $0 == path }
    }

    func resetAll() {
        for key in [Keys.onboarded, Keys.scanRoots, Keys.devRoots, Keys.ignored, Keys.retention, Keys.menuBar, Keys.containers, Keys.appearance, Keys.deletePermanently, Keys.cleanupFrequency, Keys.cleanupScheduleMode, Keys.lastScheduledCleanup, Keys.lastScheduledSummary, Keys.autoUpdate, Keys.lastUpdateCheck] {
            defaults.removeObject(forKey: key)
        }
        hasOnboarded = false
        scanRoots = Self.standardRoots
        developerRoots = []
        ignoredPaths = []
        historyRetentionDays = 90
        showMenuBar = true
        includeAppContainers = false
        appearance = .auto
        deletePermanently = false
        cleanupFrequency = .off
        cleanupScheduleMode = .ask
        lastScheduledCleanup = nil
        lastScheduledSummary = nil
        autoUpdate = true
        lastUpdateCheck = nil
    }
}
