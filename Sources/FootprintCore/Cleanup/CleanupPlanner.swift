import Foundation

public struct CleanupSuggestion: Sendable {
    public let selected: [CleanupCandidate]
    public let selectedBytes: Int64
    public let goalBytes: Int64?
    public let shortfallBytes: Int64
    public let notes: [String]
}

public struct PlanSummary: Sendable {
    public let items: [CleanupCandidate]
    public let totalBytes: Int64
    public let overlapping: [CleanupCandidate]
    public let consequences: [String]
    public let nonReversibleCount: Int
    public let lowConfidenceCount: Int
    public let needsReviewCount: Int

    public var requiresStrongConfirmation: Bool {
        nonReversibleCount > 0 || lowConfidenceCount > 0
    }
}

public enum CleanupPlanner {
    public static let presetGoals: [Int64] = [5, 10, 20, 50].map { $0 * 1_000_000_000 }

    public static func rank(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        candidates.sorted { a, b in
            if a.riskLevel != b.riskLevel { return a.riskLevel < b.riskLevel }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            if a.eligibility != b.eligibility { return a.eligibility == .eligible }
            return a.estimatedReclaimableBytes > b.estimatedReclaimableBytes
        }
    }

    public static func suggest(goalBytes: Int64?, candidates: [CleanupCandidate], ignoredPaths: [String] = []) -> CleanupSuggestion {
        let pool = candidates.filter { c in
            c.canBeAutoSuggested && !ignoredPaths.contains { PathTools.isSameOrDescendant(c.path, of: $0) }
        }
        var selected: [CleanupCandidate] = []
        var total: Int64 = 0
        for candidate in rank(pool) {
            if let goalBytes, total >= goalBytes { break }
            if overlaps(candidate, with: selected) { continue }
            selected.append(candidate)
            total += candidate.estimatedReclaimableBytes
        }

        var notes: [String] = []
        let shortfall = max(0, (goalBytes ?? 0) - total)
        if let goalBytes, shortfall > 0 {
            notes.append("Eligible high/medium confidence items add up to \(ByteFormatter.string(total)), which is \(ByteFormatter.string(shortfall)) short of your \(ByteFormatter.string(goalBytes)) goal.")
            let reviewOnly = candidates.filter { $0.eligibility == .needsUserReview }.reduce(0) { $0 + $1.estimatedReclaimableBytes }
            if reviewOnly > 0 {
                notes.append("Another \(ByteFormatter.string(reviewOnly)) needs your review before it can be added. These are not selected automatically.")
            }
            notes.append("Look at the Storage Explorer for large personal files you may want to handle yourself.")
        }
        if selected.isEmpty {
            notes.append("No items qualify for automatic suggestion right now.")
        }
        return CleanupSuggestion(selected: selected, selectedBytes: total, goalBytes: goalBytes, shortfallBytes: shortfall, notes: notes)
    }

    public static func overlaps(_ candidate: CleanupCandidate, with others: [CleanupCandidate]) -> Bool {
        others.contains {
            $0.id != candidate.id && (PathTools.isSameOrDescendant(candidate.path, of: $0.path) || PathTools.isSameOrDescendant($0.path, of: candidate.path))
        }
    }

    public static func summarize(_ items: [CleanupCandidate]) -> PlanSummary {
        var kept: [CleanupCandidate] = []
        var overlapping: [CleanupCandidate] = []
        for item in items.sorted(by: { $0.path.count < $1.path.count }) {
            if overlaps(item, with: kept) { overlapping.append(item) } else { kept.append(item) }
        }
        var seen = Set<String>()
        var consequences: [String] = []
        for c in kept.flatMap(\.consequences) where !seen.contains(c) {
            seen.insert(c)
            consequences.append(c)
        }
        return PlanSummary(
            items: kept,
            totalBytes: kept.reduce(0) { $0 + $1.estimatedReclaimableBytes },
            overlapping: overlapping,
            consequences: consequences,
            nonReversibleCount: kept.filter { $0.reversibility == .none }.count,
            lowConfidenceCount: kept.filter { $0.confidence == .low }.count,
            needsReviewCount: kept.filter { $0.eligibility == .needsUserReview }.count
        )
    }
}
