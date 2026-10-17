import FootprintCore
import SwiftUI

struct CleaningProgressView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                SpinningRing(lineWidth: 8)
                Image(systemName: "trash.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.brand)
                    .symbolEffect(.bounce, value: model.cleanupProgress.0)
            }
            .frame(width: 90, height: 90)
            ProgressView(value: Double(model.cleanupProgress.0), total: Double(max(model.cleanupProgress.1, 1)))
                .frame(width: 320)
                .animation(Motion.spring, value: model.cleanupProgress.0)
            Text("\(settings.deletePermanently ? "Checking and deleting items" : "Checking and moving items to Trash")… \(model.cleanupProgress.0) of \(model.cleanupProgress.1)")
                .numeric()
                .animation(Motion.snappy, value: model.cleanupProgress.0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewSheet: View {
    let summary: PlanSummary
    var permanent = false
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var acknowledged = false
    @EnvironmentObject private var model: AppModel

    private var needsAck: Bool { permanent || summary.requiresStrongConfirmation || summary.needsReviewCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last check before cleaning").font(.title2.bold())
            Text("\(summary.items.count) item(s) will \(permanent ? "be deleted permanently" : "go to the Trash") · about \(ByteFormatter.string(summary.totalBytes))")
                .font(.headline)
            if permanent {
                Label("We check each item again right before deleting it. If it changed, we skip it. Deleted items skip the Trash and cannot be put back. You can change this in Settings.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Palette.coral)
            } else {
                Text("We check each item again right before moving it. If it changed, we skip it. Nothing is deleted forever. You can put items back from the Trash.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            List(reviewOrder) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.eligibility == .needsUserReview ? "eye.circle.fill" : "trash.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(item.eligibility == .needsUserReview ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(PathTools.display(item.path))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if item.eligibility == .needsUserReview {
                        Badge(text: "Check first", symbol: "eye", tint: .orange)
                    }
                    Text(ByteFormatter.string(item.estimatedReclaimableBytes))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
                .padding(.vertical, 2)
                .help(([item.reason] + item.consequences + item.riskEvidence).joined(separator: "\n"))
                .contextMenu {
                    Button("Copy Path") { model.copyPath(item.path) }
                    Button("Reveal in Finder") { model.reveal(item.path) }
                }
            }
            .frame(minHeight: 260)
            Text("Hover an item to see what happens after removing it.")
                .font(.caption).foregroundStyle(.secondary)

            if needsAck {
                Toggle(isOn: $acknowledged) {
                    Text(ackText).font(.callout)
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Text("“Sure what it is” does not always mean safe for you.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(permanent ? "Delete \(summary.items.count) Item(s) Permanently" : "Move \(summary.items.count) Item(s) to Trash", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(permanent ? .red : nil)
                    .disabled(needsAck && !acknowledged)
            }
        }
        .padding(22)
        .frame(width: 720, height: 620)
    }

    private var reviewOrder: [CleanupCandidate] {
        summary.items.sorted {
            let a = $0.eligibility == .needsUserReview, b = $1.eligibility == .needsUserReview
            return a != b ? a : $0.estimatedReclaimableBytes > $1.estimatedReclaimableBytes
        }
    }

    private var ackText: String {
        var parts: [String] = []
        if permanent && !summary.requiresStrongConfirmation && summary.needsReviewCount == 0 {
            return "I understand these items will be deleted for good and cannot be put back."
        }
        if summary.needsReviewCount > 0 { parts.append("\(summary.needsReviewCount) item(s) marked “Check first”") }
        if summary.lowConfidenceCount > 0 { parts.append("\(summary.lowConfidenceCount) item(s) marked “Not sure”") }
        if summary.nonReversibleCount > 0 { parts.append("\(summary.nonReversibleCount) item(s) that cannot be restored") }
        let base = "I looked at the items marked at the top (\(parts.joined(separator: ", "))) and want to continue."
        return permanent ? base + " I understand they will be deleted for good." : base
    }
}

struct CleanupResultView: View {
    let result: CleanupRunResult
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Cleanup Results", subtitle: "Finished \(result.finishedAt.relative)")
                HStack(spacing: 16) {
                    SectionCard(title: result.deleted.isEmpty ? "Moved to Trash" : (result.trashed.isEmpty ? "Deleted" : "Removed")) {
                        CountUpText(target: result.moved.count).font(.largeTitle.bold()).foregroundStyle(.green)
                        Text("Estimated \(ByteFormatter.string(result.movedEstimatedBytes))").font(.caption)
                    }
                    SectionCard(title: "Skipped") { CountUpText(target: result.skipped.count).font(.largeTitle.bold()) }
                    SectionCard(title: "Failed") {
                        CountUpText(target: result.failed.count).font(.largeTitle.bold())
                            .foregroundStyle(result.failed.isEmpty ? Color.primary : Color.red)
                    }
                    SectionCard(title: "Measured free space change") {
                        Text(result.measuredChange.map { ByteFormatter.signed($0) } ?? "Unknown").font(.largeTitle.bold())
                        Text("Measured by macOS before and after").font(.caption)
                    }
                }
                .appear(1)
                if model.trashBytes > 0 {
                    TrashCard().appear(2)
                } else if !result.trashed.isEmpty {
                    Label("Items in the Trash still use space. Empty the Trash to free it. Until then you can put items back from the Trash.", systemImage: "info.circle")
                        .font(.callout)
                        .appear(2)
                }

                SectionCard(title: "Per-item results") {
                    ForEach(Array(result.items.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top) {
                            Image(systemName: icon(item.outcome))
                                .foregroundStyle(color(item.outcome))
                                .symbolEffect(.bounce, options: .nonRepeating, value: index)
                                .accessibilityLabel(item.outcome.rawValue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.candidate.title).font(.callout.bold())
                                PathText(path: item.candidate.path)
                                Text(item.message).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteFormatter.string(item.candidate.estimatedReclaimableBytes)).monospacedDigit()
                        }
                        .appear(index + 3, step: 0.04, offset: 8)
                        Divider()
                    }
                }

                HStack {
                    Button("Open Trash") { model.openTrash() }
                    Spacer()
                    Button("Scan Again") { model.startScan() }
                    Button("Done") { withAnimation(Motion.spring) { model.lastCleanup = nil } }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }

    private func icon(_ outcome: CleanupItemOutcome) -> String {
        switch outcome {
        case .movedToTrash: return "checkmark.circle"
        case .deleted: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon"
        case .skipped: return "forward.circle"
        }
    }

    private func color(_ outcome: CleanupItemOutcome) -> Color {
        switch outcome {
        case .movedToTrash, .deleted: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}

struct CountUpText: View {
    let target: Int
    @State private var value = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("\(value)")
            .monospacedDigit()
            .numeric()
            .onAppear {
                guard !reduceMotion else { value = target; return }
                withAnimation(Motion.spring.delay(0.2)) { value = target }
            }
            .accessibilityLabel("\(target)")
    }
}
