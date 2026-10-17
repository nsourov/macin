import FootprintCore
import SwiftUI

struct ScheduledCleanupCard: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var scheduler: ScheduledCleaner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.emerald)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.emerald.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scheduled cleanup").font(.headline)
                    Text(settings.cleanupFrequency == .off ? "Off. Turn it on to keep your Mac tidy by itself." : "\(settings.cleanupFrequency.title) · \(settings.cleanupScheduleMode.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("How often").font(.callout.weight(.medium))
                    Text("Macin checks for caches and build files that are safe to remove.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("How often", selection: $settings.cleanupFrequency) {
                    ForEach(CleanupFrequency.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if settings.cleanupFrequency != .off {
                Divider()
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("When it finds something").font(.callout.weight(.medium))
                        Text(settings.cleanupScheduleMode == .ask
                             ? "You get a notification and choose what to remove."
                             : "Only items Macin is sure about are moved to the Trash. You get a notification after.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Picker("When it finds something", selection: $settings.cleanupScheduleMode) {
                        ForEach(ScheduledCleanupMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if let next = settings.nextScheduledCleanup {
                            Text("Next check: \(next.formatted(date: .abbreviated, time: .shortened))").font(.callout)
                        }
                        if let summary = settings.lastScheduledSummary {
                            Text("Last time: \(summary)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if scheduler.isRunning {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(settings.cleanupScheduleMode == .ask ? "Check Now" : "Clean Now") { scheduler.runNow() }
                    }
                }
                Label("Scheduled cleanups always use the Trash, never permanent delete. Macin needs to be open or in the menu bar for them to run.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.snappy, value: settings.cleanupFrequency)
        .onChange(of: settings.cleanupFrequency) { _, value in
            if value != .off { scheduler.requestPermission() }
        }
        .card(padding: 20)
    }
}
