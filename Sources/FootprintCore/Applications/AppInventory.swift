import Foundation

public enum AppLocation: String, Sendable, CaseIterable {
    case applications = "Applications"
    case userApplications = "Your Applications"
    case system = "macOS"
    case other = "Other"
}

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let location: AppLocation
    public let modified: Date?

    public var isProtected: Bool {
        location == .system || bundleID?.hasPrefix("com.apple.") == true && path.hasPrefix("/System/")
    }

    public var isApple: Bool { bundleID?.hasPrefix("com.apple.") == true }

    public init(path: String, name: String, bundleID: String?, version: String?, location: AppLocation, modified: Date?) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.location = location
        self.modified = modified
    }
}

public struct AppDiscoveryResult: Sendable {
    public let apps: [InstalledApp]
    public let scannedRoots: [String]
    public let skippedRoots: [String]
}

public enum AppDiscovery {
    public static func defaultRoots(home: URL = PathTools.home) -> [(URL, AppLocation)] {
        [
            (URL(fileURLWithPath: "/Applications"), .applications),
            (home.appendingPathComponent("Applications"), .userApplications),
            (URL(fileURLWithPath: "/System/Applications"), .system)
        ]
    }

    public static func discover(roots: [(URL, AppLocation)] = defaultRoots()) -> AppDiscoveryResult {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        var scanned: [String] = []
        var skipped: [String] = []

        func visit(_ dir: URL, location: AppLocation, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles]) else { return }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                guard values?.isDirectory == true else { continue }
                if entry.pathExtension == "app" {
                    let key = entry.standardizedFileURL.path
                    guard seen.insert(key).inserted, let app = read(entry, location: location) else { continue }
                    apps.append(app)
                } else if depth < 2 {
                    visit(entry, location: location, depth: depth + 1)
                }
            }
        }

        for (root, location) in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.isReadableFile(atPath: root.path) else {
                skipped.append(root.path)
                continue
            }
            scanned.append(root.path)
            visit(root, location: location, depth: 1)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return AppDiscoveryResult(apps: apps, scannedRoots: scanned, skippedRoots: skipped)
    }

    public static func read(_ url: URL, location: AppLocation) -> InstalledApp? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return InstalledApp(
            path: url.standardizedFileURL.path,
            name: name,
            bundleID: (info?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            version: info?["CFBundleShortVersionString"] as? String ?? info?["CFBundleVersion"] as? String,
            location: location,
            modified: modified
        )
    }
}

public enum DiskUsage {
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .linkCountKey, .fileResourceIdentifierKey]
        let values = try? url.resourceValues(forKeys: Set(keys + [.isDirectoryKey, .isSymbolicLinkKey]))
        if values?.isSymbolicLink == true { return 0 }
        if values?.isDirectory != true {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var linked = Set<NSObject>()
        for case let file as URL in enumerator {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if (v.linkCount ?? 1) > 1, let id = v.fileResourceIdentifier as? NSObject {
                guard linked.insert(id).inserted else { continue }
            }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}

public enum RelatedCategory: String, Sendable, CaseIterable {
    case caches = "Caches"
    case logs = "Logs"
    case savedState = "Saved window state"
    case preferences = "Preferences"
    case support = "App data"
    case webData = "Web data"
    case containers = "Container"
    case groupContainers = "Shared container"
    case launchAgents = "Startup item"
}

public enum AssociationConfidence: String, Sendable, Comparable {
    case high = "Sure"
    case medium = "Likely"
    case low = "Maybe"

    private var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum RelatedRisk: String, Sendable {
    case regenerable = "Rebuilt automatically"
    case persistent = "App keeps its data here"
    case preferences = "Your settings for this app"
    case userData = "May hold your documents"
}

public struct RelatedItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let category: RelatedCategory
    public let bytes: Int64
    public let confidence: AssociationConfidence
    public let risk: RelatedRisk
    public let evidence: String
    public let defaultSelected: Bool
}

public enum RelatedDataScanner {
    public static func scan(for app: InstalledApp, home: URL = PathTools.home) -> [RelatedItem] {
        let fm = FileManager.default
        let lib = home.appendingPathComponent("Library")
        var items: [RelatedItem] = []
        var seen = Set<String>()

        func add(_ url: URL, _ category: RelatedCategory, _ confidence: AssociationConfidence, _ risk: RelatedRisk, _ evidence: String) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), fm.fileExists(atPath: path) else { return }
            if let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { return }
            seen.insert(path)
            let selected = confidence == .high && risk == .regenerable
            items.append(RelatedItem(path: path, category: category, bytes: DiskUsage.allocatedSize(of: url), confidence: confidence, risk: risk, evidence: evidence, defaultSelected: selected))
        }

        if let id = app.bundleID {
            let exact = "Named exactly after the app's ID (\(id))"
            add(lib.appendingPathComponent("Caches/\(id)"), .caches, .high, .regenerable, exact)
            add(lib.appendingPathComponent("Logs/\(id)"), .logs, .high, .regenerable, exact)
            add(lib.appendingPathComponent("Saved Application State/\(id).savedState"), .savedState, .high, .preferences, exact)
            add(lib.appendingPathComponent("Preferences/\(id).plist"), .preferences, .high, .preferences, exact)
            add(lib.appendingPathComponent("Application Support/\(id)"), .support, .high, .persistent, exact)
            add(lib.appendingPathComponent("HTTPStorages/\(id)"), .webData, .high, .persistent, exact)
            add(lib.appendingPathComponent("WebKit/\(id)"), .webData, .high, .persistent, exact)
            add(lib.appendingPathComponent("Containers/\(id)"), .containers, .high, .userData, exact)

            for entry in (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("Group Containers").path)) ?? [] where entry.hasSuffix("." + id) || entry == "group." + id {
                add(lib.appendingPathComponent("Group Containers/\(entry)"), .groupContainers, .medium, .userData, "Shared folder whose name ends with the app's ID")
            }
            for entry in (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent("LaunchAgents").path)) ?? [] where entry.hasPrefix(id + ".") || entry == id + ".plist" {
                add(lib.appendingPathComponent("LaunchAgents/\(entry)"), .launchAgents, .high, .persistent, "Startup file named after the app's ID")
            }

            let parts = id.split(separator: ".").map(String.init)
            if parts.count >= 3, !app.isApple {
                let vendor = parts[1]
                let product = parts[parts.count - 1]
                let prefix = vendor.lowercased() + " "
                let shortName = app.name.lowercased().hasPrefix(prefix) ? String(app.name.dropFirst(prefix.count)) : app.name
                let bases: [(String, RelatedCategory, RelatedRisk)] = [
                    ("Application Support", .support, .persistent),
                    ("Caches", .caches, .regenerable),
                    ("Logs", .logs, .regenerable)
                ]
                for (base, category, risk) in bases {
                    let dir = lib.appendingPathComponent(base)
                    guard let vendorDir = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).first(where: { $0.caseInsensitiveCompare(vendor) == .orderedSame }) else { continue }
                    let entries = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(vendorDir).path)) ?? []
                    for entry in entries where entry.caseInsensitiveCompare(product) == .orderedSame || entry.caseInsensitiveCompare(shortName) == .orderedSame {
                        add(dir.appendingPathComponent(vendorDir).appendingPathComponent(entry), category, .medium, risk, "Inside the \(vendorDir) folder and named after the app")
                    }
                }
            }
        }

        if !app.isApple, app.name.count >= 3 {
            let byName = "Same name as the app. Could belong to something else"
            add(lib.appendingPathComponent("Application Support/\(app.name)"), .support, .low, .persistent, byName)
            add(lib.appendingPathComponent("Caches/\(app.name)"), .caches, .low, .regenerable, byName)
            add(lib.appendingPathComponent("Logs/\(app.name)"), .logs, .low, .regenerable, byName)
        }

        return items.sorted { ($0.confidence, -$0.bytes) < ($1.confidence, -$1.bytes) }
    }
}
