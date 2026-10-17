import Foundation

public enum CleanupFrequency: String, CaseIterable, Sendable, Identifiable {
    case off, daily, weekly, monthly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }

    public func nextRun(after last: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .off: return nil
        case .daily: return calendar.date(byAdding: .day, value: 1, to: last)
        case .weekly: return calendar.date(byAdding: .weekOfYear, value: 1, to: last)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: last)
        }
    }

    public func isDue(last: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard self != .off else { return false }
        guard let last else { return true }
        guard let next = nextRun(after: last, calendar: calendar) else { return false }
        return now >= next
    }
}

public enum ScheduledCleanupMode: String, CaseIterable, Sendable, Identifiable {
    case ask, automatic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return "Ask me first"
        case .automatic: return "Clean automatically"
        }
    }
}

public enum ScheduledCleanupPolicy {
    public static let minimumBytes: Int64 = 50_000_000

    public static func pick(_ candidates: [CleanupCandidate], skipping unchecked: Set<String>, ignoredPaths: [String]) -> [CleanupCandidate] {
        let pool = candidates.filter { $0.canBeAutoSuggested && $0.confidence == .high && !unchecked.contains($0.path) }
        return CleanupPlanner.suggest(goalBytes: nil, candidates: pool, ignoredPaths: ignoredPaths).selected
    }
}
