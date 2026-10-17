import FootprintCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            LocationSettings().tabItem { Label("Locations", systemImage: "folder") }
            IgnoreSettings().tabItem { Label("Ignored", systemImage: "eye.slash") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Delete files permanently (skip the Trash)", isOn: $settings.deletePermanently)
            Toggle("Show in menu bar", isOn: $settings.showMenuBar)
            Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            if let error = settings.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Keep history for", selection: $settings.historyRetentionDays) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("180 days").tag(180)
                Text("1 year").tag(365)
            }
            Text("Macin never scans in the background. Scans run only when you start them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct LocationSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Scan locations") {
                FolderList(paths: $settings.scanRoots).frame(height: 110)
                Button("Restore Standard (Home + Applications)") { settings.scanRoots = AppSettings.standardRoots }
            }
            Section("Developer project folders") {
                FolderList(paths: $settings.developerRoots, addTitle: "Add Project Folder…").frame(height: 90)
                Text("node_modules is only suggested inside these folders.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Include app containers (~/Library/Containers)", isOn: $settings.includeAppContainers)
            Text("May trigger macOS prompts asking to access other apps' data.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct IgnoreSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text("These paths are skipped in scans and never suggested for cleanup.").font(.callout)
            List(selection: $selection) {
                ForEach(settings.ignoredPaths, id: \.self) { Text(PathTools.display($0)).tag($0) }
            }
            .listStyle(.bordered)
            HStack {
                Button("Stop Ignoring") {
                    if let selection { settings.unignore(selection) }
                    selection = nil
                }
                .disabled(selection == nil)
                Spacer()
                FolderList.AddButton(title: "Add Path…") { settings.ignore($0) }
            }
        }
        .padding()
    }
}

private struct PrivacySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmHistory = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("What stays on this Mac") {
                Text("Scan summaries, folder sizes and cleanup records are stored only in your Application Support folder. Nothing is uploaded. No analytics, no account.")
                    .font(.callout)
                Text("History file: \(PathTools.display(model.history.databaseURL.path))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Data controls") {
                Button("Delete All Scan History…", role: .destructive) { confirmHistory = true }
                Button("Reset App Data…", role: .destructive) { confirmReset = true }
            }
        }
        .padding()
        .confirmationDialog("Delete all scan history?", isPresented: $confirmHistory) {
            Button("Delete History", role: .destructive) { model.deleteAllHistory() }
        } message: { Text("Your files are not touched.") }
        .confirmationDialog("Reset all Macin data and settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetAppData() }
        } message: { Text("Removes history and preferences. Your files are not touched.") }
    }
}

extension FolderList {
    struct AddButton: View {
        let title: String
        let onPick: (String) -> Void

        var body: some View {
            Button(title) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { return }
                panel.urls.forEach { onPick($0.standardizedFileURL.path) }
            }
        }
    }
}
