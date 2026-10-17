import Charts
import FootprintCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var currentID: UUID?
    @State private var previousID: UUID?
    @State private var comparison: ScanComparison?
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "History", subtitle: "Small summaries of each scan, stored only on this Mac.")
                if model.sessions.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Each scan saves a small summary on this Mac so you can see what grew."))
                } else {
                    trendCard.appear(1)
                    compareCard.appear(2)
                    if let comparison {
                        ComparisonDetails(comparison: comparison)
                            .id("\(comparison.current.id)-\(comparison.previous.id)")
                            .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                    sessionsCard.appear(3)
                }
                cleanupCard.appear(4)
                SectionCard(title: "Retention") {
                    Text("Scan summaries are kept for \(settings.historyRetentionDays) days, only on this Mac. File contents are never stored.")
                        .font(.callout)
                    Button("Delete All History…", role: .destructive) { confirmDelete = true }
                }
            }
            .animation(Motion.smooth, value: comparison.map { "\($0.current.id)-\($0.previous.id)" })
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: setDefaults)
        .onChange(of: model.sessions) { setDefaults() }
        .confirmationDialog("Delete all local scan and cleanup history?", isPresented: $confirmDelete) {
            Button("Delete History", role: .destructive) { model.deleteAllHistory() }
        } message: {
            Text("This removes saved summaries from this Mac. Your files are not touched.")
        }
    }

    private func setDefaults() {
        if currentID == nil || !model.sessions.contains(where: { $0.id == currentID }) { currentID = model.sessions.first?.id }
        if previousID == nil || !model.sessions.contains(where: { $0.id == previousID }) { previousID = model.sessions.dropFirst().first?.id }
        runCompare()
    }

    private func runCompare() {
        guard let c = model.sessions.first(where: { $0.id == currentID }),
              let p = model.sessions.first(where: { $0.id == previousID }), c.id != p.id else {
            comparison = nil
            return
        }
        Task { comparison = await model.compare(c, p) }
    }

    private var trendCard: some View {
        let points = model.sessions.reversed()
        return SectionCard(title: "Free space over time", subtitle: "System-reported available space at each scan") {
            Chart(Array(points)) { s in
                AreaMark(x: .value("Date", s.startedAt), y: .value("Available GB", Double(s.availableBytes) / 1e9))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", s.startedAt), y: .value("Available GB", Double(s.availableBytes) / 1e9))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Date", s.startedAt), y: .value("Available GB", Double(s.availableBytes) / 1e9))
                    .symbolSize(40)
            }
            .chartYAxisLabel("GB available")
            .frame(height: 180)
            .accessibilityLabel("Available space trend")
        }
    }

    private var compareCard: some View {
        SectionCard(title: "Compare scans") {
            HStack {
                Picker("Current", selection: $currentID) {
                    ForEach(model.sessions) { Text(label($0)).tag(Optional($0.id)) }
                }
                Picker("Previous", selection: $previousID) {
                    ForEach(model.sessions) { Text(label($0)).tag(Optional($0.id)) }
                }
            }
            .onChange(of: currentID) { runCompare() }
            .onChange(of: previousID) { runCompare() }
            if model.sessions.count < 2 {
                Text("Run another scan later to compare.").foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ s: ScanSessionSummary) -> String {
        "\(s.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(s.status.rawValue)"
    }

    private var sessionsCard: some View {
        SectionCard(title: "Saved scans") {
            ForEach(model.sessions) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("\(s.roots.map(PathTools.display).joined(separator: ", ")) · \(s.coverageText)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(ByteFormatter.string(s.scannedAllocated)).monospacedDigit()
                    Text(s.status.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 70)
                }
            }
        }
    }

    private var cleanupCard: some View {
        SectionCard(title: "Cleanup runs") {
            if model.cleanupRuns.isEmpty {
                Text("No cleanups yet.").foregroundStyle(.secondary)
            }
            ForEach(model.cleanupRuns) { r in
                HStack {
                    Text(r.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text("\(r.movedCount) moved · \(r.skippedCount) skipped · \(r.failedCount) failed").font(.caption)
                    Text("est. \(ByteFormatter.string(r.estimatedBytes))").font(.caption).foregroundStyle(.secondary)
                    Text("measured \(r.measuredChange.map { ByteFormatter.signed($0) } ?? "—")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ComparisonDetails: View {
    let comparison: ScanComparison
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionCard(title: comparison.isComparable ? "Changes" : "Changes (limited comparison)",
                    subtitle: "Free space changed by \(ByteFormatter.signed(comparison.availableDelta))") {
            ForEach(comparison.caveats, id: \.self) { Label($0, systemImage: "info.circle").font(.caption) }
            Divider()
            Text("By category").font(.subheadline.bold())
            ForEach(comparison.categoryDeltas.filter { $0.delta != 0 }) { d in
                HStack {
                    Label(d.category.title, systemImage: d.category.symbol)
                    Spacer()
                    Text("\(ByteFormatter.string(d.previous)) → \(ByteFormatter.string(d.current))").foregroundStyle(.secondary)
                    Text(ByteFormatter.signed(d.delta)).monospacedDigit().frame(width: 100, alignment: .trailing)
                }
            }
            Divider()
            Text("Folders that changed most").font(.subheadline.bold())
            if comparison.directoryDeltas.isEmpty {
                Text("No matching folders changed by a notable amount.").foregroundStyle(.secondary)
            }
            ForEach(comparison.directoryDeltas.prefix(15)) { d in
                HStack {
                    Image(systemName: d.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .accessibilityLabel(d.delta > 0 ? "Grew" : "Shrank")
                    Button(PathTools.display(d.path)) { model.reveal(d.path) }
                        .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormatter.signed(d.delta)).monospacedDigit()
                }
            }
        }
    }
}
