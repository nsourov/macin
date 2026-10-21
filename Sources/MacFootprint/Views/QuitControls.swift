import AppKit
import SwiftUI

struct QuitMenuItems: View {
    let appPath: String
    @EnvironmentObject private var apps: ApplicationsModel

    private var name: String {
        apps.app(forPath: appPath)?.name ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    }

    var body: some View {
        if apps.canQuit(path: appPath) {
            Button("Quit \(name)") { apps.quit(path: appPath, force: false) }
            Button("Force Quit \(name)…") { QuitConfirm.forceQuit(name: name, path: appPath, apps: apps) }
        }
    }
}

struct QuitButton: View {
    let name: String
    let appPath: String
    @EnvironmentObject private var apps: ApplicationsModel

    var body: some View {
        Menu {
            Button("Force Quit…") { QuitConfirm.forceQuit(name: name, path: appPath, apps: apps) }
        } label: {
            Label("Quit", systemImage: "xmark.circle")
        } primaryAction: {
            apps.quit(path: appPath, force: false)
        }
        .fixedSize()
        .help("Ask \(name) to quit. It can save your work first.")
    }
}

enum QuitConfirm {
    @MainActor
    static func forceQuit(name: String, path: String, apps: ApplicationsModel) {
        let alert = NSAlert()
        alert.messageText = "Force quit \(name)?"
        alert.informativeText = "\(name) will close right away. Anything you haven't saved in it will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            apps.quit(path: path, force: true)
        }
    }
}
