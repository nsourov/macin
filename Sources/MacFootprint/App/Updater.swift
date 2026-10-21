import AppKit
import FootprintCore
import Foundation

@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        case ready(String)
        case installing
        case failed(String)
    }

    enum Trigger {
        case automatic, menu, settings
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @Published private(set) var state: State = .idle

    private let settings: AppSettings
    private let latestURL = URL(string: "https://api.github.com/repos/nsourov/macin/releases/latest")!
    private let assetName = "Macin.dmg"
    private let bundleID = "com.macin.app"
    private var staged: URL?
    private var loop: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var canInstall: Bool {
        Bundle.main.bundleIdentifier == bundleID && Bundle.main.bundleURL.pathExtension == "app"
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func start() {
        guard loop == nil, canInstall else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func checkIfDue() async {
        guard settings.autoUpdate else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 20 * 60 * 60 { return }
        await check(.automatic)
    }

    func check(_ trigger: Trigger) async {
        if case .ready(let version) = state {
            if trigger != .settings { askToRestart(version) }
            return
        }
        guard !isBusy else { return }
        guard canInstall else {
            finish(.failed("Updates work only in the installed Macin app."), trigger)
            return
        }
        state = .checking
        do {
            var request = URLRequest(url: latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Macin/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("Could not reach GitHub. Try again later.")
            }
            settings.lastUpdateCheck = Date()
            guard let release = try AppRelease.parseGitHub(data, assetName: assetName),
                  VersionOrder.isNewer(release.version, than: currentVersion) else {
                finish(.upToDate, trigger)
                return
            }
            state = .downloading(release.version)
            staged = try await Self.prepare(release, bundleID: bundleID, replacing: Bundle.main.bundleURL)
            state = .ready(release.version)
            if trigger != .settings { askToRestart(release.version) }
        } catch {
            finish(.failed(error.localizedDescription), trigger)
        }
    }

    private func finish(_ result: State, _ trigger: Trigger) {
        state = result
        guard trigger == .menu else { return }
        let alert = NSAlert()
        switch result {
        case .upToDate:
            alert.messageText = "Macin is up to date"
            alert.informativeText = "You have the newest version, \(currentVersion)."
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Could not check for updates"
            alert.informativeText = message
        default:
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func askToRestart(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Macin \(version) is ready"
        alert.informativeText = "Restart Macin to finish the update. It only takes a few seconds."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { installAndRestart() }
    }

    func installAndRestart() {
        guard case .ready = state, let staged else { return }
        let target = Bundle.main.bundleURL
        state = .installing
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            self.staged = nil
            state = .failed("Could not replace Macin in \(target.deletingLastPathComponent().path). \(error.localizedDescription)")
            return
        }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), target.path
        ]
        try? relaunch.run()
        AppDelegate.allowQuit = true
        NSApp.terminate(nil)
    }

    nonisolated private static func prepare(_ release: AppRelease, bundleID: String, replacing target: URL) async throws -> URL {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        let (file, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? fm.removeItem(at: file)
            throw UpdateError("The download did not finish. Try again later.")
        }
        let dmg = work.appendingPathComponent("Macin.dmg")
        try fm.moveItem(at: file, to: dmg)
        defer { try? fm.removeItem(at: dmg) }

        let mount = work.appendingPathComponent("mount")
        let app = work.appendingPathComponent("Macin.app")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        do {
            try run("/usr/bin/ditto", [mount.appendingPathComponent("Macin.app").path, app.path])
        } catch {
            try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              VersionOrder.compare(version, release.version) == .orderedSame else {
            throw UpdateError("The downloaded update does not look like Macin \(release.version).")
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError("The downloaded update failed its signature check.")
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed while preparing the update.")
        }
    }
}
