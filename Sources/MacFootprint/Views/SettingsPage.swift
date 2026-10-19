import FootprintCore
import SwiftUI

struct SettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Settings", subtitle: "Make Macin work the way you like.")
                appearanceCard
                cleanupCard
                generalCard
            }
            .padding(24)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Appearance", symbol: "paintbrush.fill", color: Palette.sky)
            HStack(spacing: 12) {
                ForEach(AppearanceMode.allCases) { mode in
                    AppearanceTile(mode: mode, selected: settings.appearance == mode) {
                        withAnimation(Motion.snappy) { settings.appearance = mode }
                    }
                }
            }
            Text("Auto follows your Mac's light or dark setting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 20)
    }

    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Cleanup", symbol: "trash.fill", color: Palette.amber)
            switchRow("Delete files permanently",
                      detail: settings.deletePermanently
                        ? "Cleaned items are deleted right away and free space at once. They cannot be put back."
                        : "Cleaned items go to the Trash, so you can put them back. Empty the Trash to free the space.",
                      isOn: $settings.deletePermanently)
            if settings.deletePermanently {
                Label("Be careful: permanently deleted files cannot be recovered.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.coral)
                    .transition(.opacity)
            }
        }
        .animation(Motion.snappy, value: settings.deletePermanently)
        .card(padding: 20)
    }

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("General", symbol: "gearshape.fill", color: Palette.slate)
            switchRow("Show in menu bar", detail: "See memory and disk at a glance. Closing Macin keeps it running here.", isOn: $settings.showMenuBar)
            Divider()
            switchRow("Open at login", detail: "Start Macin when you log in to your Mac.", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            if let error = settings.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
    }

    private func switchRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }

    private func sectionTitle(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color))
            Text(title).font(.headline)
        }
    }
}

private struct AppearanceTile: View {
    let mode: AppearanceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                Label(mode.title, systemImage: mode.symbol)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Palette.teal.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Palette.teal : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .light: window(dark: false)
        case .dark: window(dark: true)
        case .auto:
            HStack(spacing: 0) {
                window(dark: false)
                window(dark: true)
            }
        }
    }

    private func window(dark: Bool) -> some View {
        let bg = dark ? Color(white: 0.16) : Color(white: 0.96)
        let bar = dark ? Color(white: 0.3) : Color(white: 0.82)
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 5, height: 5)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 5, height: 5)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                }
                Capsule().fill(Palette.teal).frame(width: 40, height: 5)
                Capsule().fill(bar).frame(width: 60, height: 5)
                Capsule().fill(bar).frame(width: 30, height: 5)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
    }
}
