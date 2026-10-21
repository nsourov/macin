import Foundation

public struct AppRelease: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let downloadURL: URL

    public init(version: String, notes: String, downloadURL: URL) {
        self.version = version
        self.notes = notes
        self.downloadURL = downloadURL
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    public static func parseGitHub(_ data: Data, assetName: String) throws -> AppRelease? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard release.draft != true, release.prerelease != true,
              let asset = release.assets.first(where: { $0.name == assetName }),
              asset.browser_download_url.scheme == "https" else { return nil }
        return AppRelease(version: VersionOrder.clean(release.tag_name), notes: release.body ?? "", downloadURL: asset.browser_download_url)
    }
}

public enum VersionOrder {
    public static func clean(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }

    public static func parts(_ version: String) -> [Int] {
        clean(version).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parts(lhs), b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}
