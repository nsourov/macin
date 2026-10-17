import Foundation

public struct NodeModulesDetector: CandidateDetector {
    public let id = "node.node-modules"
    public let version = 1
    public let name = "node_modules in project roots"

    public static let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"]

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        var results: [CleanupCandidate] = []
        ProjectSearch.walk(context, targets: ["node_modules"]) { node in
            if let candidate = evaluate(node, context: context) { results.append(candidate) }
        }
        return results
    }

    func evaluate(_ node: FileNode, context: DetectionContext) -> CleanupCandidate? {
        guard node.allocatedSize > 0, DetectorHelpers.isRealDirectory(node.url) else { return nil }
        let project = node.url.deletingLastPathComponent()
        let fm = context.fileManager
        let hasManifest = fm.fileExists(atPath: project.appendingPathComponent("package.json").path)
        let lockfile = Self.lockfiles.first { fm.fileExists(atPath: project.appendingPathComponent($0).path) }

        var confidence: Confidence
        var eligibility: Eligibility
        var reasons: [String] = []
        var risk: [String] = []
        var riskLevel: RiskLevel = .low

        switch (hasManifest, lockfile) {
        case (true, .some(let lock)):
            confidence = .high
            eligibility = .eligible
            reasons.append("Project has package.json and \(lock), so dependencies can be reinstalled with the same versions")
        case (true, .none):
            confidence = .medium
            eligibility = .needsUserReview
            reasons.append("Project has package.json but no lockfile")
            risk.append("Reinstalling may pick newer package versions")
            riskLevel = .medium
        default:
            confidence = .low
            eligibility = .informationalOnly
            reasons.append("No package.json next to this folder, so the owner project is unclear")
            risk.append("May contain manually placed or patched files")
            riskLevel = .high
        }

        if DetectorHelpers.isRecentlyModified(node.modified, now: context.now, window: 60 * 60) {
            if eligibility == .eligible { eligibility = .needsUserReview }
            risk.append("Changed in the last hour; you may be working on this project")
            if riskLevel == .low { riskLevel = .medium }
        }

        return CleanupCandidate(
            detectorID: id,
            detectorVersion: version,
            url: node.url,
            title: ProjectSearch.projectName(project, home: context.home) + " · JavaScript packages (node_modules)",
            itemKind: .directory,
            logicalSizeBytes: node.logicalSize,
            allocatedSizeBytes: node.allocatedSize,
            classification: .projectDependency,
            source: .projectDependencies,
            confidence: confidence,
            confidenceReasons: reasons,
            eligibility: eligibility,
            riskLevel: riskLevel,
            riskEvidence: risk.isEmpty ? ["Installed packages only; your source code is outside this folder"] : risk,
            reason: "Installed JavaScript packages for this project.",
            consequences: [
                "Run your package manager's install command before working on this project again",
                "Needs internet access to reinstall",
                "Any manual edits or patches inside node_modules will be lost"
            ],
            actionType: .moveToTrash,
            reversibility: .expected,
            lastModified: node.modified,
            identity: ItemIdentity.read(node.url)
        )
    }
}
