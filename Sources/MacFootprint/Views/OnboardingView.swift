import AppKit
import FootprintCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var forward = true
    @State private var useStandard = true
    @State private var customRoots: [String] = []
    @State private var devRoots: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                Group {
                    switch step {
                    case 0: welcome
                    case 1: scope
                    default: developer
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
            Spacer(minLength: 0)
            HStack {
                if step > 0 {
                    Button("Back") { go(-1) }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                stepDots
                Spacer()
                Button("Skip for now") { finish(scan: false) }
                if step < 2 {
                    Button("Continue") { go(1) }
                        .buttonStyle(.borderedProminent)
                        .disabled(step == 1 && !useStandard && customRoots.isEmpty)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Scan") { finish(scan: true) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
        .padding(32)
        .frame(width: 600, height: 500)
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Macin").font(.title.bold())
                    Text("See what uses your storage, why, and what you can safely reclaim.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("lock.fill", .teal, "Private by design", "Everything stays on this Mac. No account, no uploads.").appear(1, step: 0.08)
                feature("hand.raised.fill", .blue, "3 easy steps", "Scan, check what we picked, then move it to the Trash. Nothing is removed without your OK.").appear(2, step: 0.08)
                feature("trash.fill", .orange, "Undo-friendly", "Removals go to the Trash, so you can put them back.").appear(3, step: 0.08)
                feature("pause.circle.fill", .teal, "Lightweight", "No background scanning. Scans run only when you ask.").appear(4, step: 0.08)
            }
            .padding(.top, 4)
        }
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: i == step ? 18 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
        .accessibilityLabel("Step \(step + 1) of 3")
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should we scan?").font(.title2.bold())
            Picker("", selection: $useStandard.animation(Motion.spring)) {
                Text("Standard scan (your Home folder and Applications)").tag(true)
                Text("Only folders I choose").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if !useStandard {
                FolderList(paths: $customRoots, addTitle: "Add Folder…")
                    .frame(height: 110)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About permissions").font(.callout.bold())
                    Text("macOS may ask if Macin can read Desktop, Documents or Downloads. You can say no; those folders will simply be listed as not scanned.")
                    Text("We do not ask for Full Disk Access. Without it, some protected folders are skipped and shown in Scan Details. You can grant it later in System Settings if you want; the app cannot grant it itself.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var developer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer folders (optional)").font(.title2.bold())
            Text("Pick folders where you keep code projects. Macin will look for regenerable items like node_modules only inside these folders, and only when the project has a package.json.")
                .foregroundStyle(.secondary)
            FolderList(paths: $devRoots, addTitle: "Add Project Folder…")
                .frame(height: 150)
            Text("Xcode build data and known tool caches are checked automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        withAnimation(Motion.spring) { step += delta }
    }

    private func finish(scan: Bool) {
        if !useStandard && !customRoots.isEmpty {
            settings.scanRoots = customRoots
        } else {
            settings.scanRoots = AppSettings.standardRoots
        }
        settings.developerRoots = devRoots
        settings.hasOnboarded = true
        dismiss()
        if scan { model.startScan() }
    }
}

struct FolderList: View {
    @Binding var paths: [String]
    var addTitle = "Add Folder…"
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(paths, id: \.self) { path in
                    Label(PathTools.display(path), systemImage: "folder").tag(path)
                }
            }
            .listStyle(.bordered)
            HStack {
                Button(addTitle) { add() }
                Button("Remove") {
                    if let selection { paths.removeAll { $0 == selection } }
                    selection = nil
                }
                .disabled(selection == nil)
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !paths.contains(path) { paths.append(path) }
        }
    }
}
