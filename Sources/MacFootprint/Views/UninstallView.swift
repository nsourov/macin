import AppKit
import FootprintCore
import SwiftUI

struct UninstallView: View {
    let app: InstalledApp
    let related: [RelatedItem]
    var onCancel: () -> Void
    var onFinish: () -> Void

    @EnvironmentObject private var apps: ApplicationsModel
    @EnvironmentObject private var settings: AppSettings
    @State private var picked: Set<String> = []
    @State private var acknowledged = false
    @State private var working = false
    @State private var quitting = false
    @State private var result: UninstallResult?

    private var permanent: Bool { settings.deletePermanently }
    private var isRunning: Bool { apps.running.contains(app.path) }
    private var block: String? { apps.uninstaller(mode: settings.removalMode).blockReason(for: app, checkRunning: false) }
    private var needsPassword: Bool { !FileManager.default.isDeletableFile(atPath: app.path) }
    private var appBytes: Int64 { apps.sizes[app.path] ?? 0 }
    private var chosen: [RelatedItem] { related.filter { picked.contains($0.path) } }
    private var totalBytes: Int64 { appBytes + chosen.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                done(result)
            } else {
                review
            }
        }
        .frame(width: 660, height: 680)
        .onAppear {
            picked = Set(related.filter { $0.confidence == .high && $0.risk != .userData }.map(\.path))
        }
    }

    private var review: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uninstall \(app.name)?").font(.title2.bold())
                    Text(permanent
                         ? "The app and the items you pick will be deleted for good."
                         : "The app and the items you pick go to the Trash. You can put them back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let block {
                        banner(block, "lock.fill", Palette.slate)
                    } else if isRunning {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.amber)
                            Text("\(app.name) is open. Quit it first so nothing is lost.").font(.callout)
                            Spacer()
                            if quitting { ProgressView().controlSize(.small) }
                            Button("Quit \(app.name)") {
                                quitting = true
                                apps.quit(app)
                                Task {
                                    try? await Task.sleep(for: .seconds(4))
                                    apps.refreshRunning()
                                    quitting = false
                                }
                            }
                            .disabled(quitting)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.amber.opacity(0.1)))
                    } else if needsPassword {
                        banner("This app was installed for all users. macOS may ask for your password.", "key.fill", Palette.sky)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("THE APP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        row(icon: "app.dashed", color: Palette.teal, title: app.name, subtitle: PathTools.display(app.path), bytes: appBytes, isOn: .constant(true), locked: true)
                    }
                    .card(padding: 16)

                    if !related.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("ITS DATA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button(picked.count == related.count ? "Pick none" : "Pick all") {
                                    picked = picked.count == related.count ? [] : Set(related.map(\.path))
                                }
                                .buttonStyle(.link).font(.caption)
                            }
                            ForEach(related) { item in
                                row(icon: "folder", color: color(item.risk), title: item.category.rawValue,
                                    subtitle: "\(item.confidence.rawValue) · \(PathTools.display(item.path))",
                                    bytes: item.bytes, isOn: binding(item.path), locked: false)
                                    .help(item.evidence)
                            }
                            if related.contains(where: { $0.risk == .userData }) {
                                Label("Containers and shared folders may hold your documents. Only pick them if you are sure.", systemImage: "exclamationmark.shield")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .card(padding: 16)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Frees about \(ByteFormatter.string(totalBytes))").font(.headline).numeric()
                Text("App + \(chosen.count) data item(s)").font(.caption).foregroundStyle(.secondary)
            }
            if permanent {
                Toggle("I understand this can't be undone", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button {
                run()
            } label: {
                if working {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Removing…") }
                } else {
                    Text(permanent ? "Delete Permanently" : "Move to Trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(permanent ? .red : nil)
            .disabled(working || block != nil || isRunning || (permanent && !acknowledged))
        }
        .controlSize(.large)
        .padding(16)
    }

    private func run() {
        working = true
        Task {
            let outcome = await apps.uninstall(app, removeApp: true, items: chosen, mode: settings.removalMode)
            working = false
            withAnimation(Motion.smooth) { result = outcome }
        }
    }

    private func done(_ result: UninstallResult) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: result.appRemoved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(result.appRemoved ? Palette.emerald : Palette.amber)
            VStack(spacing: 6) {
                Text(result.appRemoved ? "\(app.name) is uninstalled" : "\(app.name) was not removed").font(.title2.bold())
                Text(summary(result)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                stat("Removed", "\(result.removed.count) item(s)")
                stat("Estimated", ByteFormatter.string(result.removedBytes))
                if let change = result.measuredChange, change > 0 {
                    stat("Free space gained", ByteFormatter.string(change))
                }
            }
            if !result.problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not removed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(result.problems) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.coral)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).font(.callout.weight(.medium))
                                Text(entry.message).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { apps.reveal(entry.path) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                        }
                    }
                }
                .card(padding: 14)
                .frame(maxWidth: 520)
            }
            Spacer()
            Button("Done") { result.appRemoved ? onFinish() : onCancel() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ result: UninstallResult) -> String {
        guard result.appRemoved else { return "Nothing was changed for the app. See the reason below." }
        if result.removed.contains(where: { $0.outcome == .movedToTrash }) {
            return "Everything is in the Trash. Empty the Trash to get the space back, or put things back if you change your mind."
        }
        return "Everything was deleted."
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func banner(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.1)))
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { picked.contains(path) },
            set: { on in if on { picked.insert(path) } else { picked.remove(path) } }
        )
    }

    private func row(icon: String, color: Color, title: String, subtitle: String, bytes: Int64, isOn: Binding<Bool>, locked: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: isOn).toggleStyle(.checkbox).labelsHidden().disabled(locked)
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteFormatter.string(bytes)).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    private func color(_ risk: RelatedRisk) -> Color {
        switch risk {
        case .regenerable: return Palette.emerald
        case .persistent: return Palette.amber
        case .preferences: return Palette.sky
        case .userData: return Palette.coral
        }
    }
}
