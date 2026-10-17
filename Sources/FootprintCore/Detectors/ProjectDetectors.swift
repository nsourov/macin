import Foundation

enum ProjectSearch {
    static let skipDescending: Set<String> = ["Library", ".Trash", ".git", ".hg", ".svn", "node_modules", "Applications"]

    static let genericFolders: Set<String> = ["src-tauri", "android", "ios", "app", "web", "frontend", "backend", "client", "server"]

    static func projectName(_ project: URL, home: URL) -> String {
        let base = home.standardizedFileURL.path
        let path = project.standardizedFileURL.path
        guard PathTools.isDescendant(path, of: base) else { return project.lastPathComponent }
        let parts = path.dropFirst(base.count).split(separator: "/").map(String.init)
        guard let first = parts.first, let last = parts.last else { return project.lastPathComponent }
        if parts.count == 1 || genericFolders.contains(last) { return first }
        return "\(first)/\(last)"
    }

    static func roots(_ context: DetectionContext) -> [URL] {
        context.developerRoots.isEmpty ? [context.home] : context.developerRoots
    }

    static func walk(_ context: DetectionContext, targets: Set<String>, visit: (FileNode) -> Void) {
        var seen = Set<String>()
        for root in roots(context) {
            guard let rootNode = context.node(root) else { continue }
            rootNode.forEachNode { node in
                if Task.isCancelled { return false }
                guard node.isContainer else { return false }
                if node === rootNode { return true }
                if targets.contains(node.name) {
                    if seen.insert(node.path).inserted { visit(node) }
                    return false
                }
                if skipDescending.contains(node.name) || node.name.hasPrefix(".") { return false }
                return true
            }
        }
    }
}

public struct ProjectArtifactRule: Sendable {
    public let folder: String
    public let markers: [String]
    public let title: String
    public let reason: String
    public let consequences: [String]
    public let confidence: Confidence
}

public struct ProjectBuildOutputDetector: CandidateDetector {
    public let id = "project.build-output"
    public let version = 1
    public let name = "Project build output"

    public let minimumBytes: Int64

    public static let rules: [ProjectArtifactRule] = [
        ProjectArtifactRule(folder: ".next", markers: ["next.config.js", "next.config.mjs", "next.config.ts", "package.json"],
                            title: "Next.js build cache", reason: "Build output and cache made by Next.js.",
                            consequences: ["Next start or build of this project takes longer"], confidence: .high),
        ProjectArtifactRule(folder: "target", markers: ["Cargo.toml"],
                            title: "Rust build output", reason: "Compiled files made by cargo.",
                            consequences: ["Next cargo build of this project takes longer"], confidence: .high),
        ProjectArtifactRule(folder: "build", markers: ["build.gradle", "build.gradle.kts"],
                            title: "Gradle build output", reason: "Compiled files made by Gradle.",
                            consequences: ["Next Gradle build of this project takes longer"], confidence: .high),
        ProjectArtifactRule(folder: ".gradle", markers: ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"],
                            title: "Gradle project cache", reason: "Per-project cache made by Gradle.",
                            consequences: ["Gradle rebuilds this cache on next build"], confidence: .high),
        ProjectArtifactRule(folder: ".dart_tool", markers: ["pubspec.yaml"],
                            title: "Dart/Flutter tool cache", reason: "Generated files made by Dart and Flutter tools.",
                            consequences: ["Run `flutter pub get` before working on this project again"], confidence: .high),
        ProjectArtifactRule(folder: ".turbo", markers: ["turbo.json", "package.json"],
                            title: "Turborepo cache", reason: "Cached task output made by Turborepo.",
                            consequences: ["Next build runs without cache and takes longer"], confidence: .high),
        ProjectArtifactRule(folder: ".parcel-cache", markers: ["package.json"],
                            title: "Parcel cache", reason: "Cache made by the Parcel bundler.",
                            consequences: ["Next build takes longer"], confidence: .high),
        ProjectArtifactRule(folder: ".svelte-kit", markers: ["svelte.config.js", "svelte.config.ts", "package.json"],
                            title: "SvelteKit build output", reason: "Generated files made by SvelteKit.",
                            consequences: ["Next dev or build takes longer"], confidence: .high),
        ProjectArtifactRule(folder: ".nuxt", markers: ["nuxt.config.ts", "nuxt.config.js", "package.json"],
                            title: "Nuxt build output", reason: "Generated files made by Nuxt.",
                            consequences: ["Next dev or build takes longer"], confidence: .high),
        ProjectArtifactRule(folder: ".angular", markers: ["angular.json"],
                            title: "Angular cache", reason: "Build cache made by the Angular CLI.",
                            consequences: ["Next build takes longer"], confidence: .high)
    ]

    public init(minimumBytes: Int64 = 20_000_000) { self.minimumBytes = minimumBytes }

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        let byFolder = Dictionary(grouping: Self.rules, by: \.folder)
        var results: [CleanupCandidate] = []
        ProjectSearch.walk(context, targets: Set(byFolder.keys)) { node in
            guard node.allocatedSize >= minimumBytes, DetectorHelpers.isRealDirectory(node.url) else { return }
            let project = node.url.deletingLastPathComponent()
            let fm = context.fileManager
            guard let rule = byFolder[node.name]?.first(where: { rule in
                rule.markers.contains { fm.fileExists(atPath: project.appendingPathComponent($0).path) }
            }) else { return }
            let marker = rule.markers.first { fm.fileExists(atPath: project.appendingPathComponent($0).path) } ?? ""

            var eligibility: Eligibility = .eligible
            var risk: [String] = []
            if DetectorHelpers.isRecentlyModified(node.modified, now: context.now, window: 60 * 60) {
                eligibility = .needsUserReview
                risk.append("Changed in the last hour; you may be working on this project")
            }
            results.append(CleanupCandidate(
                detectorID: id,
                detectorVersion: version,
                url: node.url,
                title: "\(ProjectSearch.projectName(project, home: context.home)) · \(rule.title)",
                itemKind: .directory,
                logicalSizeBytes: node.logicalSize,
                allocatedSizeBytes: node.allocatedSize,
                classification: .buildOutput,
                source: .projectDependencies,
                confidence: rule.confidence,
                confidenceReasons: ["Found next to \(marker), so this is generated by the project's build tool"],
                eligibility: eligibility,
                riskLevel: risk.isEmpty ? .low : .medium,
                riskEvidence: risk.isEmpty ? ["Generated files only; your source code is outside this folder"] : risk,
                reason: rule.reason,
                consequences: rule.consequences,
                actionType: .moveToTrash,
                reversibility: .expected,
                lastModified: node.modified,
                identity: ItemIdentity.read(node.url)
            ))
        }
        return results
    }
}

public struct AppCachesDetector: CandidateDetector {
    public let id = "caches.app-caches"
    public let version = 1
    public let name = "App caches"

    public let minimumBytes: Int64

    public init(minimumBytes: Int64 = 50_000_000) { self.minimumBytes = minimumBytes }

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        let cachesURL = context.home.appendingPathComponent("Library/Caches")
        guard let caches = context.node(cachesURL) else { return [] }
        let known = Set(KnownCacheDetector.rules.map { context.home.appendingPathComponent($0.relativePath).standardizedFileURL.path })
        let running = context.runningBundleIDs.map { $0.lowercased() }

        return caches.children.compactMap { node in
            guard node.isContainer, node.allocatedSize >= minimumBytes else { return nil }
            guard !node.name.hasPrefix("com.apple."), !known.contains(node.path) else { return nil }
            guard DetectorHelpers.isRealDirectory(node.url) else { return nil }

            let key = node.name.lowercased()
            let ownerRunning = running.contains { $0 == key || $0.contains(key) || key.contains($0) }
            var eligibility: Eligibility = .eligible
            var risk: [String] = []
            if ownerRunning {
                eligibility = .needsUserReview
                risk.append("The app that owns this cache seems to be open; quit it first")
            }
            if DetectorHelpers.isRecentlyModified(node.modified, now: context.now) {
                eligibility = .needsUserReview
                risk.append("Changed in the last 15 minutes; an app may be using it")
            }
            return CleanupCandidate(
                detectorID: id,
                detectorVersion: version,
                url: node.url,
                title: "\(Self.displayName(node.name)) cache",
                itemKind: .directory,
                logicalSizeBytes: node.logicalSize,
                allocatedSizeBytes: node.allocatedSize,
                classification: .cache,
                source: .caches,
                confidence: .medium,
                confidenceReasons: ["Stored in your Caches folder, where apps keep files they can make again"],
                eligibility: eligibility,
                riskLevel: risk.isEmpty ? .low : .medium,
                riskEvidence: risk.isEmpty ? ["Apps rebuild their cache when needed"] : risk,
                reason: "Temporary files an app saved to load faster.",
                consequences: ["The app may be slower the first time you open it", "Some content may download again"],
                actionType: .moveToTrash,
                reversibility: .expected,
                lastModified: node.modified,
                identity: ItemIdentity.read(node.url)
            )
        }
    }

    static func displayName(_ folder: String) -> String {
        let parts = folder.split(separator: ".")
        guard parts.count >= 3, ["com", "org", "net", "io", "ru", "us", "app", "dev", "co"].contains(String(parts[0])) else { return folder }
        return String(parts[2...].joined(separator: " "))
    }
}

public struct ElectronCachesDetector: CandidateDetector {
    public let id = "caches.electron-apps"
    public let version = 1
    public let name = "Desktop app web caches"

    public static let cacheFolders = ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs", "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/CacheStorage"]
    public let minimumBytes: Int64

    public init(minimumBytes: Int64 = 50_000_000) { self.minimumBytes = minimumBytes }

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        let support = context.home.appendingPathComponent("Library/Application Support")
        guard let supportNode = context.node(support) else { return [] }
        let running = context.runningBundleIDs.map { $0.lowercased() }
        var results: [CleanupCandidate] = []
        for app in supportNode.children where app.isContainer {
            for folder in Self.cacheFolders {
                let url = app.url.appendingPathComponent(folder)
                guard let node = context.node(url), node.isContainer, node.allocatedSize >= minimumBytes,
                      DetectorHelpers.isRealDirectory(url) else { continue }
                let key = app.name.lowercased()
                let ownerRunning = running.contains { $0.hasSuffix("." + key) || $0.contains(key) }
                var eligibility: Eligibility = .eligible
                var risk: [String] = []
                if ownerRunning {
                    eligibility = .needsUserReview
                    risk.append("\(app.name) is open; quit it first")
                }
                if DetectorHelpers.isRecentlyModified(node.modified, now: context.now) {
                    eligibility = .needsUserReview
                    risk.append("Changed in the last 15 minutes; the app may be using it")
                }
                results.append(CleanupCandidate(
                    detectorID: id,
                    detectorVersion: version,
                    url: url,
                    title: "\(app.name) · \(folder)",
                    itemKind: .directory,
                    logicalSizeBytes: node.logicalSize,
                    allocatedSizeBytes: node.allocatedSize,
                    classification: .cache,
                    source: .caches,
                    confidence: .medium,
                    confidenceReasons: ["Standard cache folder name used by Chromium and Electron apps"],
                    eligibility: eligibility,
                    riskLevel: risk.isEmpty ? .low : .medium,
                    riskEvidence: risk.isEmpty ? ["Web cache only; your settings and data are kept"] : risk,
                    reason: "Web and code cache of the \(app.name) app.",
                    consequences: ["\(app.name) may start slower the first time", "Some content may download again"],
                    actionType: .moveToTrash,
                    reversibility: .expected,
                    lastModified: node.modified,
                    identity: ItemIdentity.read(url)
                ))
            }
        }
        return results
    }
}

public struct DevToolStorageDetector: CandidateDetector {
    public let id = "devtools.storage"
    public let version = 1
    public let name = "Developer tool storage"

    public let minimumBytes: Int64

    public static let locations: [(path: String, title: String, reason: String, hint: String)] = [
        ("Library/Developer/CoreSimulator/Devices", "iOS Simulators",
         "Simulator devices and the apps and data inside them.",
         "In Terminal run `xcrun simctl delete unavailable`, or delete simulators in Xcode › Window › Devices and Simulators."),
        (".android/avd", "Android emulators (whole)",
         "Android virtual devices. Their snapshots are listed above so you can remove them here.",
         "To delete a whole emulator, use Android Studio › Device Manager."),
        ("Library/Android/sdk", "Android SDK (whole)",
         "The full Android SDK. Old versions inside it are listed above so you can remove them here.",
         "To remove more, use Android Studio › Settings › SDK Manager."),
        ("Library/Developer/Xcode/Archives", "Xcode archives",
         "App builds you archived in Xcode. Needed to symbolicate crash reports.",
         "Delete old archives in Xcode › Window › Organizer.")
    ]

    public init(minimumBytes: Int64 = 500_000_000) { self.minimumBytes = minimumBytes }

    public func detect(in context: DetectionContext) async -> [CleanupCandidate] {
        Self.locations.compactMap { item in
            let url = context.home.appendingPathComponent(item.path)
            guard let node = context.node(url), node.allocatedSize >= minimumBytes else { return nil }
            return CleanupCandidate(
                detectorID: id,
                detectorVersion: version,
                url: url,
                title: item.title,
                itemKind: .directory,
                logicalSizeBytes: node.logicalSize,
                allocatedSizeBytes: node.allocatedSize,
                classification: .unknown,
                source: .other,
                confidence: .high,
                confidenceReasons: ["Standard location used by this tool"],
                eligibility: .informationalOnly,
                riskLevel: .medium,
                riskEvidence: ["Contains things you may still use; the tool itself knows which parts are safe to remove"],
                reason: item.reason,
                consequences: ["Remove parts from inside the tool so it stays consistent"],
                actionType: .adapterHandoff,
                reversibility: .none,
                lastModified: node.modified,
                identity: nil,
                handoffHint: item.hint
            )
        }
    }
}
