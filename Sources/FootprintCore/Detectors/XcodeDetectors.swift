import Foundation

public struct XcodeDerivedDataDetector: CandidateDetector {
    public let id = "xcode.derived-data"
    public let version = 1
    public let name = "Xcode DerivedData"
    public static let xcodeBundleID = "com.apple.dt.Xcode"

    public init() {}

    public func derivedDataURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    public static func looksLikeDerivedDataChild(_ url: URL, fm: FileManager) -> (Bool, String?) {
        let info = url.appendingPathComponent("info.plist")
        if let data = fm.contents(atPath: info.path),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let workspace = plist["WorkspacePath"] as? String {
            return (true, workspace)
        }
        let name = url.lastPathComponent
        if let dash = name.lastIndex(of: "-") {
            let suffix = name[name.index(after: dash)...]
            if suffix.count == 28, suffix.allSatisfy({ $0.isLowercase && $0.isLetter }) { return (true, nil) }
        }
        return (false, nil)
    }

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        let base = derivedDataURL(home: context.home)
        let fm = context.fileManager
        let xcodeRunning = context.runningBundleIDs.contains(Self.xcodeBundleID)
        var results: [CleanupCandidate] = []

        for child in DetectorHelpers.children(of: base, fm: fm) where DetectorHelpers.isRealDirectory(child) {
            let name = child.lastPathComponent
            guard let node = context.node(child) else { continue }

            if name == "ModuleCache.noindex" || name == "SymbolCache.noindex" {
                results.append(make(child, node: node, title: "Shared module cache", confidence: .high,
                                    reasons: ["Standard Xcode shared cache folder inside DerivedData"],
                                    eligibility: xcodeRunning ? .needsUserReview : .eligible,
                                    risk: xcodeRunning ? ["Xcode is running and may be using this cache"] : [],
                                    workspace: nil, context: context))
                continue
            }

            let (recognized, workspace) = Self.looksLikeDerivedDataChild(child, fm: fm)
            var reasons: [String] = []
            var riskEvidence: [String] = []
            var confidence: Confidence = recognized ? .high : .medium
            var eligibility: Eligibility = .eligible

            if recognized {
                reasons.append(workspace != nil ? "Xcode metadata links it to a workspace" : "Folder name matches Xcode's DerivedData naming")
            } else {
                reasons.append("Inside DerivedData, but the folder layout is not recognized")
            }
            if let workspace {
                if !fm.fileExists(atPath: workspace) {
                    reasons.append("The original project no longer exists at its recorded path")
                } else {
                    reasons.append("The project still exists, so Xcode will rebuild this on next build")
                }
            }
            if xcodeRunning {
                eligibility = .needsUserReview
                riskEvidence.append("Xcode is running; a build may be using this folder")
            }
            if DetectorHelpers.isRecentlyModified(node.modified, now: context.now) {
                eligibility = .needsUserReview
                confidence = min(confidence, .medium)
                riskEvidence.append("Changed in the last 15 minutes; it may be in active use")
            }

            let title = workspace.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? name
            results.append(make(child, node: node, title: title, confidence: confidence, reasons: reasons,
                                eligibility: eligibility, risk: riskEvidence, workspace: workspace, context: context))
        }
        return results
    }

    private func make(_ url: URL, node: FileNode, title: String, confidence: Confidence, reasons: [String], eligibility: Eligibility, risk: [String], workspace: String?, context: DetectionContext) -> CleanupCandidate {
        CleanupCandidate(
            detectorID: id,
            detectorVersion: version,
            url: url,
            title: title,
            itemKind: .directory,
            logicalSizeBytes: node.logicalSize,
            allocatedSizeBytes: node.allocatedSize,
            classification: .buildOutput,
            source: .xcode,
            confidence: confidence,
            confidenceReasons: reasons,
            eligibility: eligibility,
            riskLevel: risk.isEmpty ? .low : .medium,
            riskEvidence: risk.isEmpty ? ["Regenerable build output; no project source code lives here"] : risk,
            reason: "Xcode build output (DerivedData). Xcode recreates it when you build.",
            consequences: [
                "Next build of this project will take longer",
                "Xcode will re-index the project",
                "Build logs and test results stored here will be gone"
            ],
            actionType: .moveToTrash,
            reversibility: .expected,
            lastModified: node.modified,
            identity: ItemIdentity.read(url)
        )
    }
}

public struct XcodeDeviceSupportDetector: CandidateDetector {
    public let id = "xcode.device-support"
    public let version = 1
    public let name = "Xcode device support"

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        let platforms = ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport"]
        var results: [CleanupCandidate] = []
        for platform in platforms {
            let base = context.home.appendingPathComponent("Library/Developer/Xcode/\(platform)")
            for child in DetectorHelpers.children(of: base, fm: context.fileManager) where DetectorHelpers.isRealDirectory(child) {
                guard let node = context.node(child) else { continue }
                results.append(CleanupCandidate(
                    detectorID: id,
                    detectorVersion: version,
                    url: child,
                    title: "\(platform.replacingOccurrences(of: " DeviceSupport", with: "")) \(child.lastPathComponent)",
                    itemKind: .directory,
                    logicalSizeBytes: node.logicalSize,
                    allocatedSizeBytes: node.allocatedSize,
                    classification: .deviceSupport,
                    source: .xcode,
                    confidence: .medium,
                    confidenceReasons: ["Standard Xcode device support folder", "Cannot tell if you still debug on a device with this OS version"],
                    eligibility: .needsUserReview,
                    riskLevel: .low,
                    riskEvidence: ["Xcode copies these again when a matching device connects"],
                    reason: "Debug symbols Xcode copied from a connected device.",
                    consequences: [
                        "Next time a device with this OS version connects, Xcode copies symbols again (can take several minutes)"
                    ],
                    actionType: .moveToTrash,
                    reversibility: .expected,
                    lastModified: node.modified,
                    identity: ItemIdentity.read(child)
                ))
            }
        }
        return results
    }
}

public struct SimulatorCachesDetector: CandidateDetector {
    public let id = "xcode.simulator-caches"
    public let version = 1
    public let name = "Simulator caches"

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        let url = context.home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
        guard DetectorHelpers.isRealDirectory(url), let node = context.node(url), node.allocatedSize > 0 else { return [] }
        let simRunning = context.runningBundleIDs.contains("com.apple.iphonesimulator")
        return [CleanupCandidate(
            detectorID: id,
            detectorVersion: version,
            url: url,
            title: "CoreSimulator caches",
            itemKind: .directory,
            logicalSizeBytes: node.logicalSize,
            allocatedSizeBytes: node.allocatedSize,
            classification: .cache,
            source: .xcode,
            confidence: .medium,
            confidenceReasons: ["Standard CoreSimulator cache location"],
            eligibility: simRunning ? .needsUserReview : .eligible,
            riskLevel: .low,
            riskEvidence: simRunning ? ["Simulator is running"] : ["Cache only; simulator devices and their data live elsewhere"],
            reason: "Cached data used to speed up iOS Simulator.",
            consequences: ["Simulator may start slower the first time", "Dyld caches are rebuilt on next launch"],
            actionType: .moveToTrash,
            reversibility: .expected,
            lastModified: node.modified,
            identity: ItemIdentity.read(url)
        )]
    }
}
