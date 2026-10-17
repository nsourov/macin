import Foundation

public struct TrashEmptyResult: Sendable, Equatable {
    public let removedCount: Int
    public let removedBytes: Int64
    public let failedCount: Int
}

public struct TrashEmptier: Sendable {
    public let trashURL: URL

    public init(trashURL: URL = PathTools.home.appendingPathComponent(".Trash", isDirectory: true)) {
        self.trashURL = trashURL
    }

    public func items() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    public func size() -> Int64 {
        items().reduce(0) { $0 + Self.allocatedSize(of: $1) }
    }

    public func empty() -> TrashEmptyResult {
        var removed = 0
        var bytes: Int64 = 0
        var failed = 0
        for item in items() where item.lastPathComponent != ".DS_Store" {
            let size = Self.allocatedSize(of: item)
            do {
                try FileManager.default.removeItem(at: item)
                removed += 1
                bytes += size
            } catch {
                failed += 1
            }
        }
        return TrashEmptyResult(removedCount: removed, removedBytes: bytes, failedCount: failed)
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
