import AppKit
import FootprintCore
import SwiftUI

struct HandoffTool {
    let name: String
    let bundleID: String
}

extension CleanupCandidate {
    var handoffTool: HandoffTool? {
        let p = path
        if p.contains("/Library/Android/") || p.contains("/.android/") {
            return HandoffTool(name: "Android Studio", bundleID: "com.google.android.studio")
        }
        if p.contains("/Library/Developer/") { return HandoffTool(name: "Xcode", bundleID: "com.apple.dt.Xcode") }
        if p.contains("/Google/Chrome/") { return HandoffTool(name: "Chrome", bundleID: "com.google.Chrome") }
        if detectorID.hasPrefix("docker") { return HandoffTool(name: "Docker", bundleID: "com.docker.docker") }
        if p.contains("/.lmstudio/") || p.contains("/lm-studio") { return HandoffTool(name: "LM Studio", bundleID: "ai.elementlabs.lmstudio") }
        return nil
    }

    var handoffCommand: String? {
        guard let hint = handoffHint ?? consequences.first(where: { $0.contains("`") }) else { return nil }
        let parts = hint.components(separatedBy: "`")
        return parts.count >= 3 ? parts[1] : nil
    }

    var rowSymbol: String {
        switch classification {
        case .buildOutput: return "hammer.fill"
        case .projectDependency: return "shippingbox.fill"
        case .cache: return "tray.full.fill"
        case .localModel: return "cpu.fill"
        case .deviceSupport: return "iphone"
        case .containerResource: return "cube.box.fill"
        case .unknown: return "wrench.and.screwdriver.fill"
        }
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for candidate: CleanupCandidate) -> NSImage? {
        if let cached = cache[candidate.path] { return cached }
        let found = lookup(candidate)
        cache[candidate.path] = found
        return found
    }

    static func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func lookup(_ candidate: CleanupCandidate) -> NSImage? {
        if let tool = candidate.handoffTool, let url = appURL(bundleID: tool.bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let parts = candidate.url.pathComponents
        if let i = parts.firstIndex(of: "Caches"), i + 1 < parts.count, let url = appURL(bundleID: parts[i + 1]) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let i = parts.firstIndex(of: "Application Support"), i + 1 < parts.count {
            let name = parts[i + 1]
            for dir in ["/Applications", PathTools.home.appendingPathComponent("Applications").path] {
                let app = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: app) { return NSWorkspace.shared.icon(forFile: app) }
            }
        }
        return nil
    }
}

struct CandidateIcon: View {
    let candidate: CleanupCandidate

    var body: some View {
        if let image = AppIcons.icon(for: candidate) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: candidate.rowSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(candidate.source.color.gradient))
                .frame(width: 24, height: 24)
        }
    }
}

struct HandoffButtons: View {
    let candidate: CleanupCandidate
    var compact = false
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    @State private var confirmSimulators = false
    @State private var running = false
    @State private var resultMessage: String?

    private var isSimulators: Bool { candidate.path.hasSuffix("/CoreSimulator/Devices") }

    var body: some View {
        HStack(spacing: 6) {
            if isSimulators {
                Button { confirmSimulators = true } label: {
                    Label(running ? "Removing…" : "Remove Broken Simulators", systemImage: "trash")
                }
                .disabled(running)
                .help("Runs Apple's tool: xcrun simctl delete unavailable")
                .confirmationDialog("Remove simulators that no longer work?", isPresented: $confirmSimulators) {
                    Button("Remove", role: .destructive) {
                        running = true
                        Task {
                            resultMessage = await model.removeUnavailableSimulators()
                            running = false
                        }
                    }
                } message: {
                    Text("This removes simulators whose iOS version is no longer installed. Your working simulators are kept. This cannot be undone from the Trash.")
                }
                .alert(resultMessage ?? "", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                }
            }
            if !(compact && isSimulators), let tool = candidate.handoffTool, let url = AppIcons.appURL(bundleID: tool.bundleID) {
                Button {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Label("Open \(tool.name)", systemImage: "arrow.up.forward.app")
                }
                .help("Open \(tool.name) to remove what you do not need")
            }
            if let command = candidate.handoffCommand, !(compact && candidate.handoffTool.flatMap { AppIcons.appURL(bundleID: $0.bundleID) } != nil) {
                Button {
                    model.copyPath(command)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help("Copies: \(command)  — paste it in Terminal")
            }
        }
        .controlSize(.small)
        .animation(Motion.snappy, value: copied)
    }
}
