import Foundation

public struct KnownCacheRule: Sendable {
    public let relativePath: String
    public let title: String
    public let confidence: Confidence
    public let reason: String
    public let consequences: [String]
    public let ownerBundlePrefix: String?

    public init(_ relativePath: String, title: String, confidence: Confidence, reason: String, consequences: [String], ownerBundlePrefix: String? = nil) {
        self.relativePath = relativePath
        self.title = title
        self.confidence = confidence
        self.reason = reason
        self.consequences = consequences
        self.ownerBundlePrefix = ownerBundlePrefix
    }
}

public struct KnownCacheDetector: CandidateDetector {
    public let id = "caches.known-tools"
    public let version = 1
    public let name = "Known developer tool caches"

    public static let rules: [KnownCacheRule] = [
        KnownCacheRule("Library/Caches/Homebrew", title: "Homebrew download cache", confidence: .high,
                       reason: "Downloaded package files kept by Homebrew after install.",
                       consequences: ["Homebrew downloads packages again if you reinstall them"]),
        KnownCacheRule("Library/Caches/pip", title: "pip cache", confidence: .high,
                       reason: "Python packages downloaded by pip.",
                       consequences: ["pip downloads packages again on next install", "Offline installs will not work until re-downloaded"]),
        KnownCacheRule("Library/Caches/Yarn", title: "Yarn cache", confidence: .high,
                       reason: "Packages downloaded by Yarn.",
                       consequences: ["Yarn downloads packages again on next install", "Offline installs will not work until re-downloaded"]),
        KnownCacheRule("Library/Caches/pnpm", title: "pnpm cache", confidence: .high,
                       reason: "Metadata cached by pnpm.",
                       consequences: ["pnpm refetches package metadata"]),
        KnownCacheRule(".npm/_cacache", title: "npm cache", confidence: .high,
                       reason: "Packages downloaded by npm.",
                       consequences: ["npm downloads packages again on next install", "Offline installs will not work until re-downloaded"]),
        KnownCacheRule("Library/Caches/CocoaPods", title: "CocoaPods cache", confidence: .high,
                       reason: "Pod sources downloaded by CocoaPods.",
                       consequences: ["pod install downloads pods again"]),
        KnownCacheRule("Library/Caches/org.swift.swiftpm", title: "Swift Package Manager cache", confidence: .high,
                       reason: "Package repositories cached by SwiftPM.",
                       consequences: ["Swift packages are fetched again on next resolve"]),
        KnownCacheRule("Library/Caches/go-build", title: "Go build cache", confidence: .high,
                       reason: "Compiled Go build output.",
                       consequences: ["Next Go build will take longer"]),
        KnownCacheRule("Library/Caches/node-gyp", title: "node-gyp headers", confidence: .high,
                       reason: "Node.js headers used to build native modules.",
                       consequences: ["node-gyp downloads headers again when needed"]),
        KnownCacheRule("Library/Caches/typescript", title: "TypeScript type cache", confidence: .high,
                       reason: "Type definitions cached by editors.",
                       consequences: ["Editors fetch type definitions again"]),
        KnownCacheRule("Library/Caches/ms-playwright", title: "Playwright browsers", confidence: .medium,
                       reason: "Browser builds downloaded by Playwright.",
                       consequences: ["Run `npx playwright install` again before tests", "Large re-download"]),
        KnownCacheRule("Library/Caches/JetBrains", title: "JetBrains IDE caches", confidence: .medium,
                       reason: "Indexes and caches of JetBrains IDEs.",
                       consequences: ["IDEs re-index projects on next open (can be slow)"],
                       ownerBundlePrefix: "com.jetbrains."),
        KnownCacheRule(".gradle/caches", title: "Gradle cache", confidence: .high,
                       reason: "Libraries and build files downloaded by Gradle.",
                       consequences: ["Gradle downloads libraries again on next build", "First build after this is slower"],
                       ownerBundlePrefix: "com.google.android.studio"),
        KnownCacheRule("go/pkg/mod", title: "Go module cache", confidence: .medium,
                       reason: "Go modules downloaded by `go get` and `go build`.",
                       consequences: ["Go downloads modules again on next build"]),
        KnownCacheRule(".cache/puppeteer", title: "Puppeteer browsers", confidence: .high,
                       reason: "Browser builds downloaded by Puppeteer.",
                       consequences: ["Puppeteer downloads the browser again on next install"]),
        KnownCacheRule("Library/Caches/pypoetry", title: "Poetry cache", confidence: .high,
                       reason: "Python packages downloaded by Poetry.",
                       consequences: ["Poetry downloads packages again on next install"]),
        KnownCacheRule(".cargo/registry", title: "Cargo registry cache", confidence: .medium,
                       reason: "Rust crates downloaded by cargo.",
                       consequences: ["cargo downloads crates again on next build"]),
        KnownCacheRule(".m2/repository", title: "Maven repository", confidence: .medium,
                       reason: "Java libraries downloaded by Maven.",
                       consequences: ["Maven downloads libraries again on next build"]),
        KnownCacheRule(".bun/install/cache", title: "Bun cache", confidence: .high,
                       reason: "Packages downloaded by Bun.",
                       consequences: ["Bun downloads packages again on next install"]),
        KnownCacheRule("Library/Caches/com.apple.dt.Xcode", title: "Xcode app cache", confidence: .medium,
                       reason: "General cache of the Xcode app.",
                       consequences: ["Xcode rebuilds this cache; first launch may be slower"],
                       ownerBundlePrefix: "com.apple.dt.Xcode")
    ]

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        var results: [CleanupCandidate] = []
        for rule in Self.rules {
            let url = context.home.appendingPathComponent(rule.relativePath)
            guard DetectorHelpers.isRealDirectory(url), let node = context.node(url), node.allocatedSize > 0 else { continue }

            var eligibility: Eligibility = .eligible
            var risk: [String] = []
            var confidence = rule.confidence
            if let prefix = rule.ownerBundlePrefix, context.runningBundleIDs.contains(where: { $0.hasPrefix(prefix) }) {
                eligibility = .needsUserReview
                risk.append("The app that owns this cache is running")
            }
            if DetectorHelpers.isRecentlyModified(node.modified, now: context.now) {
                eligibility = .needsUserReview
                confidence = min(confidence, .medium)
                risk.append("Changed in the last 15 minutes; a tool may be using it")
            }

            results.append(CleanupCandidate(
                detectorID: id,
                detectorVersion: version,
                url: url,
                title: rule.title,
                itemKind: .directory,
                logicalSizeBytes: node.logicalSize,
                allocatedSizeBytes: node.allocatedSize,
                classification: .cache,
                source: .caches,
                confidence: confidence,
                confidenceReasons: ["Matches a documented cache location for this tool"],
                eligibility: eligibility,
                riskLevel: risk.isEmpty ? .low : .medium,
                riskEvidence: risk.isEmpty ? ["Download/build cache; the tool recreates it as needed"] : risk,
                reason: rule.reason,
                consequences: rule.consequences,
                actionType: .moveToTrash,
                reversibility: .expected,
                lastModified: node.modified,
                identity: ItemIdentity.read(url)
            ))
        }
        return results
    }
}

public struct LocalModelsDetector: CandidateDetector {
    public let id = "ai.local-models"
    public let version = 1
    public let name = "Local AI models"

    public static let locations: [(String, String)] = [
        (".ollama/models", "Ollama models"),
        (".cache/huggingface", "Hugging Face cache"),
        (".cache/lm-studio", "LM Studio models"),
        (".lmstudio/models", "LM Studio models")
    ]

    public init() {}

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        Self.locations.compactMap { relative, title in
            let url = context.home.appendingPathComponent(relative)
            guard DetectorHelpers.isRealDirectory(url), let node = context.node(url), node.allocatedSize > 0 else { return nil }
            return CleanupCandidate(
                detectorID: id,
                detectorVersion: version,
                url: url,
                title: title,
                itemKind: .directory,
                logicalSizeBytes: node.logicalSize,
                allocatedSizeBytes: node.allocatedSize,
                classification: .localModel,
                source: .localModels,
                confidence: .high,
                confidenceReasons: ["Standard model storage location for this tool"],
                eligibility: .informationalOnly,
                riskLevel: .high,
                riskEvidence: ["Models can be very large to download again", "May include models you created or fine-tuned"],
                reason: "Downloaded AI models. Shown so you know where space goes; not offered for cleanup.",
                consequences: ["Remove models from inside the tool itself (for example `ollama rm <model>`)"],
                actionType: .informationalOnly,
                reversibility: .none,
                lastModified: node.modified,
                identity: nil,
                handoffHint: "Manage models in the tool that downloaded them."
            )
        }
    }
}
