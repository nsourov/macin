import FootprintCore
import SwiftUI

struct Badge: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
    }
}

extension Confidence {
    var plainTitle: String {
        switch self {
        case .high: return "Sure what it is"
        case .medium: return "Fairly sure"
        case .low: return "Not sure"
        }
    }

    var explanation: String {
        "How sure the app is about what this item is. It is not a promise that removing it is safe for you."
    }

    var symbol: String {
        switch self {
        case .high: return "checkmark.seal"
        case .medium: return "circle.lefthalf.filled"
        case .low: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
        }
    }
}

extension RiskLevel {
    var plainTitle: String {
        switch self {
        case .low: return "Low risk"
        case .medium: return "Some risk"
        case .high: return "High risk"
        }
    }

    var explanation: String {
        switch self {
        case .low: return "Usually comes back by itself when needed."
        case .medium: return "May need a re-download or rebuild later."
        case .high: return "Could lose work or data. Check carefully."
        }
    }

    var symbol: String {
        switch self {
        case .low: return "shield"
        case .medium: return "exclamationmark.shield"
        case .high: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .low: return .secondary
        case .medium: return .orange
        case .high: return .red
        }
    }
}

extension Eligibility {
    var plainTitle: String {
        switch self {
        case .eligible: return "Can clean"
        case .needsUserReview: return "Check first"
        case .informationalOnly: return "Info only"
        case .blocked: return "Can't clean now"
        }
    }

    var explanation: String {
        switch self {
        case .eligible: return "Safe to clean. Ticked for you by default."
        case .needsUserReview: return "Not ticked for you. Look at it first, then tick it if you want."
        case .informationalOnly: return "Shown so you know about it. The app will not remove it."
        case .blocked: return "Something is using it right now, so it cannot be removed."
        }
    }

    var symbol: String {
        switch self {
        case .eligible: return "checkmark.circle"
        case .needsUserReview: return "eye"
        case .informationalOnly: return "info.circle"
        case .blocked: return "nosign"
        }
    }
}

struct CandidateBadges: View {
    let candidate: CleanupCandidate

    var body: some View {
        HStack(spacing: 6) {
            Badge(text: candidate.riskLevel.plainTitle, symbol: candidate.riskLevel.symbol, tint: candidate.riskLevel.tint)
                .help(candidate.riskLevel.explanation)
            Badge(text: candidate.confidence.plainTitle, symbol: candidate.confidence.symbol, tint: candidate.confidence.tint)
                .help(candidate.confidence.explanation)
            Badge(text: candidate.eligibility.plainTitle, symbol: candidate.eligibility.symbol)
                .help(candidate.eligibility.explanation)
        }
    }
}

struct PathText: View {
    let path: String
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Text(PathTools.display(path))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            Button {
                model.copyPath(path)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy full path")
            .accessibilityLabel("Copy path")
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .card()
    }
}

struct ScanStatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if case .scanning(let progress) = model.scanState {
            HStack(spacing: 12) {
                SpinningRing(lineWidth: 3).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(progress.phase.rawValue).font(.callout.weight(.semibold))
                    Text("\(progress.itemsVisited.formatted()) items · \(ByteFormatter.string(progress.bytesSeen)) · \(PathTools.display(progress.currentPath))")
                        .numeric()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel") { model.cancelScan() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning: \(progress.phase.rawValue), \(progress.itemsVisited) items")
        }
    }
}

struct EmptyScanView: View {
    @EnvironmentObject private var model: AppModel
    var message = "Run a scan to see what is using your storage."

    var body: some View {
        if case .scanning(let progress) = model.scanState {
            ScanningHero(progress: progress)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 92, height: 92)
                    .background(Circle().fill(Color.accentColor.opacity(0.08)))
                    .symbolEffect(.bounce, options: .nonRepeating, value: model.isScanning)
                Text("No scan yet").font(.title2.weight(.semibold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    model.startScan()
                } label: {
                    Label("Scan Now", systemImage: "magnifyingglass").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appear(offset: 20)
        }
    }
}

struct ScanningHero: View {
    let progress: ScanProgress
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                SpinningRing(lineWidth: 10)
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Theme.brand)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .frame(width: 110, height: 110)
            Text(progress.phase.rawValue)
                .font(.title2.weight(.semibold))
                .id(progress.phase)
                .transition(.opacity.combined(with: .offset(y: 6)))
            HStack(spacing: 28) {
                VStack {
                    Text(progress.itemsVisited.formatted()).font(.title3.weight(.semibold)).monospacedDigit().numeric()
                    Text("items").font(.caption).foregroundStyle(.secondary)
                }
                VStack {
                    Text(ByteFormatter.string(progress.bytesSeen)).font(.title3.weight(.semibold)).monospacedDigit().numeric()
                    Text("measured").font(.caption).foregroundStyle(.secondary)
                }
            }
            .animation(Motion.snappy, value: progress.itemsVisited)
            Text(PathTools.display(progress.currentPath))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 460)
            Button("Cancel Scan") { model.cancelScan() }
        }
        .animation(Motion.smooth, value: progress.phase)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appear(offset: 20)
    }
}

extension Date {
    var relative: String {
        RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date())
    }
}
