import FootprintCore
import SwiftUI

struct SpaceBreakdownCard: View {
    let totals: [StorageCategory: Int64]
    let checked: Int64
    let scan: ScanResult?
    @EnvironmentObject private var model: AppModel
    @State private var openCategory: StorageCategory?

    var body: some View {
        let data = StorageCategory.allCases
            .map { ($0, totals[$0] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Where your space goes").font(.headline)
                Spacer()
                Text(scan == nil ? "From your last scan · \(ByteFormatter.string(checked)) checked" : "\(ByteFormatter.string(checked)) checked")
                    .font(.caption).foregroundStyle(.secondary)
            }
            StackedBar(data: data)
                .frame(height: 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(data, id: \.0) { item in
                    Button { if scan != nil { openCategory = item.0 } } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(item.0.color).frame(width: 10, height: 10)
                            Text(item.0.title).font(.callout).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ByteFormatter.string(item.1)).font(.callout.weight(.medium)).monospacedDigit()
                            if scan != nil {
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.035)))
                        .contentShape(Rectangle())
                        .hoverHighlight()
                    }
                    .buttonStyle(PressableStyle())
                    .help(scan == nil ? "Scan again to see what is inside" : "See what is inside \(item.0.title)")
                }
            }
        }
        .card(padding: 20)
        .sheet(item: $openCategory) { category in
            if let scan {
                CategorySheet(category: category, scan: scan)
                    .environmentObject(model)
            }
        }
    }
}

struct StorageOverview: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var apps: ApplicationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Storage", subtitle: "Your disk at a glance. Clean up whenever you like.")
                if let v = model.volume {
                    diskCard(v)
                }
                cleanupCard
                ScheduledCleanupCard()
                if model.trashBytes >= 50_000_000 {
                    TrashCard()
                }
                if let scan = model.scan {
                    SpaceBreakdownCard(totals: scan.categoryTotals, checked: scan.totalAllocated, scan: scan)
                } else if let last = model.sessions.first, !model.lastCategoryTotals.isEmpty {
                    SpaceBreakdownCard(totals: model.lastCategoryTotals, checked: last.scannedAllocated, scan: nil)
                }
                appsCard
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            model.refreshVolume()
            model.refreshTrashSize()
            apps.loadIfNeeded()
        }
    }

    private func diskCard(_ v: VolumeInfo) -> some View {
        let purgeable = max(v.availableImportantBytes - v.availableBytes, 0)
        let usedFraction = Double(v.usedBytes) / Double(max(v.totalBytes, 1))
        return HStack(spacing: 28) {
            DiskRing(volume: v).frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(v.name, systemImage: "internaldrive").font(.callout).foregroundStyle(.secondary)
                    Text(ByteFormatter.string(v.availableImportantBytes))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .numeric()
                    Text("free for you to use").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    stat("Used", ByteFormatter.string(v.usedBytes), usedFraction > 0.9 ? Palette.amber : Palette.blue)
                    stat("Total", ByteFormatter.string(v.totalBytes), Palette.slate)
                    if purgeable > 100_000_000 {
                        stat("macOS can free", ByteFormatter.string(purgeable), Palette.teal)
                            .help("Space macOS clears on its own when needed, like old caches and iCloud copies. It is already counted as free.")
                    }
                }
                if usedFraction > 0.9 {
                    Label("Your disk is almost full. Cleaning up can help.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(Palette.amber)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var cleanupCard: some View {
        HStack(spacing: 16) {
            Image(systemName: model.isScanning ? "magnifyingglass" : (model.scan == nil ? "sparkles" : "leaf.fill"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.emerald)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Palette.emerald.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).numeric()
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.isScanning {
                HStack(spacing: 8) {
                    SpinningRing(lineWidth: 3).frame(width: 16, height: 16)
                    Button("See Progress") { model.storageTab = .cleanUp }
                }
            } else if model.scan == nil {
                Button {
                    model.startScan()
                    model.storageTab = .cleanUp
                } label: {
                    Label("Start Cleanup", systemImage: "sparkles").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.emerald)
                .controlSize(.large)
            } else {
                HStack(spacing: 8) {
                    Button("Scan Again") { model.startScan() }
                    if model.planSummary.totalBytes > 0 {
                        Button {
                            model.storageTab = .cleanUp
                        } label: {
                            Label("Review & Clean", systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.emerald)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Palette.emerald.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Palette.emerald.opacity(0.22)))
    }

    private var title: String {
        if model.isScanning { return "Looking for things you can remove…" }
        if model.scan == nil { return "Free up space safely" }
        if model.planSummary.totalBytes > 0 { return "You can free \(ByteFormatter.string(model.planSummary.totalBytes))" }
        return "All tidy"
    }

    private var detail: String {
        if model.isScanning { return "This takes a minute. You can keep using your Mac." }
        if model.scan == nil {
            if let last = model.sessions.first { return "Last checked \(last.startedAt.relative). We look for caches and build files that are safe to remove." }
            return "We look for caches and build files that are safe to remove. Nothing is removed without your OK."
        }
        if model.planSummary.totalBytes > 0 { return "We picked \(model.planSummary.items.count) safe item(s). You review everything first." }
        return "Nothing safe to clean right now."
    }

    @ViewBuilder
    private var appsCard: some View {
        if !apps.apps.isEmpty {
            Button { model.selection = .applications } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.sky)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Palette.sky.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apps use \(ByteFormatter.string(apps.totalBytes))").font(.headline).numeric()
                        Text("\(apps.apps.count) apps installed. See which are the biggest and what data they keep.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .card(padding: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
    }
}
