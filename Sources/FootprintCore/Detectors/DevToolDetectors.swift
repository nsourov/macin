import Foundation

public struct DevToolCleanupDetector: CandidateDetector {
    public let id = "devtools.parts"
    public let version = 1
    public let name = "Old developer tool versions"

    public let minimumBytes: Int64

    public init(minimumBytes: Int64 = 50_000_000) {
        self.minimumBytes = minimumBytes
    }

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        var results: [CleanupCandidate] = []
        let home = context.home
        let sdk = home.appendingPathComponent("Library/Android/sdk")

        for (folder, label) in [("ndk", "Android NDK"), ("build-tools", "Android build tools")] {
            let versions = versionFolders(sdk.appendingPathComponent(folder), context: context)
            guard let newest = versions.last else { continue }
            for node in versions where node !== newest {
                append(&results, node, context: context,
                       title: "\(label) \(node.name)",
                       reason: "An older \(label) version. You also have \(newest.name).",
                       consequences: ["A project that needs exactly this version will download it again"],
                       eligibility: .needsUserReview, confidence: .medium,
                       evidence: ["Kept the newest version (\(newest.name))", "Some projects pin an exact version"])
            }
        }

        let avdRoot = home.appendingPathComponent(".android/avd")
        let usedImages = usedSystemImages(avdRoot: avdRoot, sdk: sdk)
        if let images = context.node(sdk.appendingPathComponent("system-images")) {
            for api in images.children where api.isContainer {
                for variant in api.children where variant.isContainer {
                    guard !usedImages.contains(where: { PathTools.isSameOrDescendant($0, of: variant.path) }) else { continue }
                    append(&results, variant, context: context,
                           title: "Android system image \(api.name) \(variant.name)",
                           reason: "System image that none of your emulators use.",
                           consequences: ["Android Studio downloads it again if you make an emulator with it"],
                           eligibility: .eligible, confidence: .medium,
                           evidence: ["No emulator in ~/.android/avd points to this image"])
                }
            }
        }

        if let avds = context.node(avdRoot) {
            for avd in avds.children where avd.isContainer && avd.name.hasSuffix(".avd") {
                guard let snapshots = context.node(avd.url.appendingPathComponent("snapshots")) else { continue }
                append(&results, snapshots, context: context,
                       title: "\(avd.name.replacingOccurrences(of: ".avd", with: "").replacingOccurrences(of: "_", with: " ")) snapshots",
                       reason: "Saved emulator states used for quick start.",
                       consequences: ["The emulator does a full (slower) start next time"],
                       eligibility: .eligible, confidence: .high,
                       evidence: ["Snapshots are made again automatically"])
            }
        }

        let nvmDefault = (try? String(contentsOf: home.appendingPathComponent(".nvm/alias/default"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appendRuntimeVersions(&results, root: home.appendingPathComponent(".nvm/versions/node"), context: context,
                              label: "Node.js", defaultSpec: nvmDefault, tool: "nvm")

        let pyenvGlobal = (try? String(contentsOf: home.appendingPathComponent(".pyenv/version"), encoding: .utf8))?
            .split(whereSeparator: \.isNewline).first.map(String.init)
        appendRuntimeVersions(&results, root: home.appendingPathComponent(".pyenv/versions"), context: context,
                              label: "Python", defaultSpec: pyenvGlobal, tool: "pyenv")

        if let model = context.node(home.appendingPathComponent("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel")) {
            let chromeRunning = context.runningBundleIDs.contains("com.google.Chrome")
            append(&results, model, context: context,
                   title: "Chrome on-device AI model",
                   reason: "AI model Chrome downloads for built-in AI features.",
                   consequences: ["Chrome downloads it again if an AI feature needs it"],
                   eligibility: .needsUserReview, confidence: .high,
                   evidence: chromeRunning ? ["Chrome is open; quit it first"] : ["Chrome manages this model and can download it again"])
        }
        return results
    }

    private func versionFolders(_ url: URL, context: DetectionContext) -> [FileNode] {
        guard let node = context.node(url) else { return [] }
        return node.children
            .filter { $0.isContainer }
            .sorted { $0.name.compare($1.name, options: .numeric) == .orderedAscending }
    }

    private func appendRuntimeVersions(_ results: inout [CleanupCandidate], root: URL, context: DetectionContext,
                                       label: String, defaultSpec: String?, tool: String) {
        let versions = versionFolders(root, context: context)
        guard versions.count > 1, let newest = versions.last else { return }
        let spec = defaultSpec.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
        let defaultNode = spec.flatMap { s in
            versions.last { v in
                let name = v.name.hasPrefix("v") ? String(v.name.dropFirst()) : v.name
                return name == s || name.hasPrefix(s + ".")
            }
        }
        for node in versions where node !== newest && node !== defaultNode {
            append(&results, node, context: context,
                   title: "\(label) \(node.name)",
                   reason: "An older \(label) version installed with \(tool).",
                   consequences: ["Projects that need exactly this version must install it again with \(tool)"],
                   eligibility: .needsUserReview, confidence: .medium,
                   evidence: ["Kept your default\(defaultNode.map { " (\($0.name))" } ?? "") and the newest (\(newest.name))"])
        }
    }

    private func usedSystemImages(avdRoot: URL, sdk: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: avdRoot.path) else { return [] }
        return items.filter { $0.hasSuffix(".avd") }.compactMap { avd in
            let config = avdRoot.appendingPathComponent(avd).appendingPathComponent("config.ini")
            guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("image.sysdir.1") {
                let value = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                return sdk.appendingPathComponent(value).standardizedFileURL.path
            }
            return nil
        }
    }

    private func append(_ results: inout [CleanupCandidate], _ node: FileNode, context: DetectionContext,
                        title: String, reason: String, consequences: [String],
                        eligibility: Eligibility, confidence: Confidence, evidence: [String]) {
        guard node.allocatedSize >= minimumBytes, DetectorHelpers.isRealDirectory(node.url) else { return }
        var eligibility = eligibility
        var risk = evidence
        if DetectorHelpers.isRecentlyModified(node.modified, now: context.now) {
            eligibility = .needsUserReview
            risk.append("Changed in the last 15 minutes; it may be in use")
        }
        results.append(CleanupCandidate(
            detectorID: id,
            detectorVersion: version,
            url: node.url,
            title: title,
            itemKind: .directory,
            logicalSizeBytes: node.logicalSize,
            allocatedSizeBytes: node.allocatedSize,
            classification: .unknown,
            source: .other,
            confidence: confidence,
            confidenceReasons: ["Standard location used by this tool"],
            eligibility: eligibility,
            riskLevel: eligibility == .eligible ? .low : .medium,
            riskEvidence: risk,
            reason: reason,
            consequences: consequences,
            actionType: .moveToTrash,
            reversibility: .expected,
            lastModified: node.modified,
            identity: ItemIdentity.read(node.url)
        ))
    }
}
