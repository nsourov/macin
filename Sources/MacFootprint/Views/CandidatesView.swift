import FootprintCore
import SwiftUI

enum CandidateSort: CaseIterable {
    case size, name, oldest

    var title: String {
        switch self {
        case .size: return "Biggest"
        case .name: return "Name"
        case .oldest: return "Oldest"
        }
    }
}

struct CandidatesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var amount: Int64 = 0
    @State private var showReview = false
    @State private var search = ""
    @State private var sort: CandidateSort = .size

    var body: some View {
        Group {
            if model.isCleaning {
                CleaningProgressView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let result = model.lastCleanup {
                CleanupResultView(result: result)
                    .transition(.opacity.combined(with: .offset(y: 16)))
            } else if model.scan == nil {
                EmptyScanView(message: "Run a scan. We will find safe things to remove for you.")
            } else {
                list.transition(.opacity)
            }
        }
        .animation(Motion.spring, value: model.isCleaning)
        .animation(Motion.spring, value: model.lastCleanup?.id)
        .sheet(isPresented: $showReview) {
            ReviewSheet(summary: model.planSummary, permanent: settings.deletePermanently) {
                showReview = false
                model.executePlan()
            } onCancel: {
                showReview = false
            }
        }
    }

    private var visibleCandidates: [CleanupCandidate] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let items = q.isEmpty ? model.candidates : model.candidates.filter {
            $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
        switch sort {
        case .size: return items.sorted { $0.estimatedReclaimableBytes > $1.estimatedReclaimableBytes }
        case .name: return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .oldest: return items.sorted { ($0.lastModified ?? .distantFuture) < ($1.lastModified ?? .distantFuture) }
        }
    }
    private var allCleanable: [CleanupCandidate] { model.candidates.filter(\.isSelectable) }
    private var cleanable: [CleanupCandidate] { visibleCandidates.filter(\.isSelectable) }
    private var infoOnly: [CleanupCandidate] { visibleCandidates.filter { !$0.isSelectable } }

    private var listTools: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a project or app", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .frame(maxWidth: 320)
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(CandidateSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Clean Up", subtitle: "We already picked the items that are safe to remove. Untick anything you want to keep. Nothing is removed until you click \(settings.deletePermanently ? "Delete" : "Move to Trash").")
                if allCleanable.isEmpty {
                    nothingFound
                } else {
                    summaryCard
                }
                if !model.candidates.isEmpty {
                    listTools
                }
                if !search.isEmpty && visibleCandidates.isEmpty {
                    Text("Nothing matches “\(search)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                }
                ForEach(CandidateSource.allCases, id: \.self) { source in
                    let items = cleanable.filter { $0.source == source }
                    if !items.isEmpty {
                        CandidateGroup(title: source.title, symbol: source.symbol, color: source.color, items: items, showAllItems: !search.isEmpty)
                    }
                }
                if !infoOnly.isEmpty {
                    CandidateGroup(title: "Good to know",
                                   subtitle: "Big, but this app does not remove them. Use the buttons to clean them in their own app.",
                                   symbol: "info.circle.fill", color: .gray, items: infoOnly, showAllItems: !search.isEmpty)
                        .padding(.top, 6)
                }
                if let status = model.dockerStatus {
                    Label(status.description, systemImage: "cube.box")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(Motion.smooth, value: model.candidates.map(\.id))
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var nothingFound: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 36)).foregroundStyle(.green)
            Text("Nothing to clean right now").font(.title3.weight(.semibold))
            Text("No known caches or build files were found. The app only removes things it can clearly explain.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .card()
    }

    private var summaryCard: some View {
        let summary = model.planSummary
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You can free").font(.callout).foregroundStyle(.secondary)
                Text(ByteFormatter.string(summary.totalBytes))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .numeric()
                Text("\(summary.items.count) of \(allCleanable.count) items ticked")
                    .font(.callout).foregroundStyle(.secondary).numeric()
                ForEach(model.planNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .animation(Motion.spring, value: summary.totalBytes)
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Picker("Free up", selection: $amount) {
                    Text("Everything safe").tag(Int64(0))
                    ForEach(CleanupPlanner.presetGoals, id: \.self) { Text("Only \(ByteFormatter.string($0))").tag($0) }
                }
                .fixedSize()
                .help("Pick how much space to free. We tick the safest items until we reach it.")
                .onChange(of: amount) { _, value in model.suggestPlan(goal: value == 0 ? nil : value) }
            }
        }
        .card(padding: 20)
    }

    @ViewBuilder
    private var actionBar: some View {
        if !allCleanable.isEmpty {
            let summary = model.planSummary
            HStack(spacing: 12) {
                Text(summary.items.isEmpty
                     ? "Nothing ticked"
                     : "\(summary.items.count) item(s) ticked · about \(ByteFormatter.string(summary.totalBytes))")
                    .font(.callout.weight(.medium))
                    .numeric()
                Spacer()
                Button { showReview = true } label: {
                    Label(settings.deletePermanently ? "Delete Permanently…" : "Move to Trash…", systemImage: settings.deletePermanently ? "trash.slash" : "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.deletePermanently ? .red : nil)
                .controlSize(.large)
                .disabled(summary.items.isEmpty || model.isScanning)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .animation(Motion.spring, value: model.planIDs.count)
        }
    }
}

struct CandidateGroup: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    let color: Color
    let items: [CleanupCandidate]
    var showAllItems = false
    @EnvironmentObject private var model: AppModel
    @State private var collapsed = false
    @State private var showAll = false

    private static let previewCount = 6

    var body: some View {
        let selectable = items.filter(\.isSelectable)
        let ticked = selectable.filter { model.planIDs.contains($0.id) }
        let expandedAll = showAll || showAllItems
        let visible = expandedAll ? items : Array(items.prefix(Self.previewCount))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if !selectable.isEmpty {
                    Button { model.setPlan(selectable, selected: ticked.count < selectable.count) } label: {
                        Image(systemName: ticked.count == selectable.count ? "checkmark.circle.fill"
                              : (ticked.isEmpty ? "circle" : "minus.circle.fill"))
                            .font(.system(size: 18))
                            .foregroundStyle(ticked.isEmpty ? Color.secondary : Color.accentColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PressableStyle())
                    .help(ticked.count == selectable.count ? "Untick all in this group" : "Tick all in this group")
                }
                IconTile(symbol: symbol, color: color, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(ticked.count) of \(selectable.count) ticked").font(.caption).foregroundStyle(.secondary).numeric()
                    }
                }
                Spacer()
                Text(ByteFormatter.string(items.reduce(0) { $0 + $1.estimatedReclaimableBytes }))
                    .font(.headline).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.snappy) { collapsed.toggle() } }

            if !collapsed {
                let maxBytes = items.map(\.estimatedReclaimableBytes).max() ?? 0
                ForEach(visible) { item in
                    Divider().padding(.leading, 14)
                    CandidateRow(candidate: item, maxBytes: maxBytes)
                }
                if items.count > Self.previewCount && !showAllItems {
                    Divider()
                    Button {
                        withAnimation(Motion.snappy) { showAll.toggle() }
                    } label: {
                        Text(showAll ? "Show less" : "Show all \(items.count)")
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct CandidateRow: View {
    let candidate: CleanupCandidate
    var maxBytes: Int64 = 0
    @EnvironmentObject private var model: AppModel
    @State private var expanded = false

    var body: some View {
        let inPlan = model.planIDs.contains(candidate.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if candidate.isSelectable {
                    Button { model.togglePlan(candidate) } label: {
                        Image(systemName: inPlan ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(inPlan ? Color.accentColor : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PressableStyle())
                    .help(inPlan ? "Ticked: will be moved to Trash. Click to keep it." : "Not ticked: will be kept. Click to clean it.")
                    .accessibilityLabel(inPlan ? "Keep \(candidate.title)" : "Clean \(candidate.title)")
                }
                CandidateIcon(candidate: candidate)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(candidate.url.isFileURL ? PathTools.display(candidate.path) : candidate.reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if candidate.eligibility == .needsUserReview {
                    Badge(text: "Check first", symbol: "eye", tint: .orange)
                        .help(candidate.riskEvidence.joined(separator: "\n"))
                } else if !candidate.isSelectable {
                    HandoffButtons(candidate: candidate, compact: true)
                }
                if maxBytes > 0 {
                    ProportionBar(fraction: Double(candidate.estimatedReclaimableBytes) / Double(maxBytes),
                                  color: inPlan ? .accentColor : .secondary)
                        .frame(width: 44)
                }
                Text(ByteFormatter.string(candidate.estimatedReclaimableBytes))
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.snappy) { expanded.toggle() } }

            if expanded {
                details
                    .padding(.leading, 42)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(inPlan ? Color.accentColor.opacity(0.05) : Color.clear)
        .hoverHighlight()
        .animation(Motion.snappy, value: inPlan)
        .contextMenu {
            if candidate.url.isFileURL {
                Button("Reveal in Finder") { model.reveal(candidate.path) }
                Button("Copy Path") { model.copyPath(candidate.path) }
                Divider()
                Button("Ignore in Future Scans") { model.ignore(candidate.path) }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.reason).font(.callout)
            if !candidate.consequences.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.isSelectable ? "After removing" : "Good to know").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(candidate.consequences, id: \.self) { c in
                        Label(c, systemImage: "arrow.turn.down.right").font(.caption)
                    }
                }
            }
            if let hint = candidate.handoffHint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to free this space").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(hint).font(.caption).textSelection(.enabled)
                    HandoffButtons(candidate: candidate)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue.opacity(0.07)))
            }
            HStack(spacing: 8) {
                CandidateBadges(candidate: candidate)
                    .help((candidate.confidenceReasons + candidate.riskEvidence).joined(separator: "\n"))
                Spacer()
                if candidate.url.isFileURL {
                    Button { model.reveal(candidate.path) } label: { Label("Finder", systemImage: "folder") }
                    Button { model.ignore(candidate.path) } label: { Label("Ignore", systemImage: "eye.slash") }
                        .help("Never suggest this again")
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
