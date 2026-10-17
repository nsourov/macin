import FootprintCore
import SwiftUI

struct CoverageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let scan = model.scan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PageHeader(title: "Scan Details", subtitle: "What was scanned, what was skipped, and why.")
                        rootsCard(scan.coverage).appear(1)
                        skippedCard(scan.coverage).appear(2)
                        accessCard.appear(3)
                        notesCard(scan.coverage).appear(4)
                    }
                    .padding(24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyScanView(message: "Run a scan to see what was and wasn't covered.")
            }
        }
    }

    private func rootsCard(_ coverage: ScanCoverage) -> some View {
        SectionCard(title: "Locations", subtitle: coverage.summaryText) {
            ForEach(coverage.roots) { root in
                HStack {
                    Image(systemName: icon(root.state))
                    VStack(alignment: .leading) {
                        Text(PathTools.display(root.path))
                        if let note = root.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(root.state.rawValue.capitalized).font(.caption)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func skippedCard(_ coverage: ScanCoverage) -> some View {
        let groups = Dictionary(grouping: coverage.skipped, by: \.reason)
        return SectionCard(title: "Skipped items", subtitle: "\(coverage.skippedCount) item(s) were not scanned\(coverage.skippedCount > coverage.skipped.count ? " (first \(coverage.skipped.count) listed)" : "")") {
            if coverage.skippedCount == 0 {
                Text("Nothing was skipped.").foregroundStyle(.secondary)
            }
            ForEach(Array(groups.keys).sorted { $0.rawValue < $1.rawValue }, id: \.self) { reason in
                let items = groups[reason] ?? []
                DisclosureGroup("\(items.first?.reasonText ?? reason.rawValue) — \(items.count)") {
                    ForEach(items.prefix(100)) { item in
                        PathText(path: item.path).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var accessCard: some View {
        SectionCard(title: "Want more coverage? (optional)") {
            Text("Some folders are protected by macOS privacy settings. Granting Full Disk Access lets Macin read them. This is your choice; the app cannot grant it, and everything works without it.")
                .font(.callout)
            Text("Steps: System Settings → Privacy & Security → Full Disk Access → turn on Macin. Then come back and check again.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings") { model.openFullDiskAccessSettings() }
                Button("Check Access Again") { model.startScan() }.disabled(model.isScanning)
            }
        }
    }

    private func notesCard(_ coverage: ScanCoverage) -> some View {
        SectionCard(title: "Accounting notes") {
            Text("• \(coverage.symlinksNotFollowed.formatted()) symbolic links were not followed (avoids loops and double counting).")
            Text("• \(coverage.hardLinkDuplicatesSkipped.formatted()) extra hard links were counted only once.")
            Text("• App containers are skipped by default to avoid repeated macOS prompts. You can include them in Settings.")
            Text("• APFS clones, snapshots and purgeable space mean scanned totals may not match the disk's used space.")
        }
        .font(.callout)
    }

    private func icon(_ state: RootAccessState) -> String {
        switch state {
        case .scanned: return "checkmark.circle"
        case .partial: return "circle.lefthalf.filled"
        case .inaccessible: return "lock"
        case .missing: return "questionmark.folder"
        case .ignored: return "eye.slash"
        case .cancelled: return "stop.circle"
        }
    }
}
