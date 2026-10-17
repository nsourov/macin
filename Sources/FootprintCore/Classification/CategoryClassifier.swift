import Foundation

public struct CategoryClassifier: Sendable {
    private let rules: [(prefix: String, category: StorageCategory)]
    private let nameRules: [String: StorageCategory]

    public init(home: URL = PathTools.home) {
        let h = home.path
        let raw: [(String, StorageCategory)] = [
            ("/Applications", .applications),
            ("\(h)/Applications", .applications),
            ("\(h)/Library/Caches", .cachesSupport),
            ("\(h)/Library/Logs", .cachesSupport),
            ("\(h)/Library/Application Support", .cachesSupport),
            ("\(h)/Library/Containers/com.docker.docker", .containersVMs),
            ("\(h)/Library/Group Containers/group.com.docker", .containersVMs),
            ("\(h)/.docker", .containersVMs),
            ("\(h)/.orbstack", .containersVMs),
            ("\(h)/.colima", .containersVMs),
            ("\(h)/.lima", .containersVMs),
            ("\(h)/Parallels", .containersVMs),
            ("\(h)/Virtual Machines.localized", .containersVMs),
            ("\(h)/Library/Containers/com.utmapp.UTM", .containersVMs),
            ("\(h)/Library/Developer", .developerArtifacts),
            ("\(h)/Library/Android", .developerArtifacts),
            ("\(h)/.npm", .developerArtifacts),
            ("\(h)/.pnpm-store", .developerArtifacts),
            ("\(h)/.yarn", .developerArtifacts),
            ("\(h)/.bun", .developerArtifacts),
            ("\(h)/.gradle", .developerArtifacts),
            ("\(h)/.m2", .developerArtifacts),
            ("\(h)/.cargo", .developerArtifacts),
            ("\(h)/.rustup", .developerArtifacts),
            ("\(h)/.pyenv", .developerArtifacts),
            ("\(h)/.nvm", .developerArtifacts),
            ("\(h)/.android", .developerArtifacts),
            ("\(h)/.pub-cache", .developerArtifacts),
            ("\(h)/.cocoapods", .developerArtifacts),
            ("\(h)/go", .developerArtifacts),
            ("\(h)/.ollama", .localAIModels),
            ("\(h)/.cache/huggingface", .localAIModels),
            ("\(h)/.cache/lm-studio", .localAIModels),
            ("\(h)/.lmstudio", .localAIModels),
            ("\(h)/Documents", .userFiles),
            ("\(h)/Desktop", .userFiles),
            ("\(h)/Downloads", .userFiles),
            ("\(h)/Movies", .userFiles),
            ("\(h)/Music", .userFiles),
            ("\(h)/Pictures", .userFiles),
            ("\(h)/Library/Mobile Documents", .userFiles),
            ("\(h)/Library/CloudStorage", .userFiles)
        ]
        rules = raw.sorted { $0.0.count > $1.0.count }.map { (prefix: $0.0, category: $0.1) }
        nameRules = [
            "node_modules": .developerArtifacts,
            "DerivedData": .developerArtifacts,
            ".venv": .developerArtifacts,
            "venv": .developerArtifacts,
            "Pods": .developerArtifacts,
            ".gradle": .developerArtifacts,
            ".build": .developerArtifacts
        ]
    }

    public func category(forPath path: String, name: String, kind: ItemKind) -> StorageCategory? {
        if kind == .package, name.hasSuffix(".app") { return .applications }
        if let byName = nameRules[name], kind != .file { return byName }
        if name.hasSuffix(".gguf") || name.hasSuffix(".safetensors") { return .localAIModels }
        for rule in rules where PathTools.isSameOrDescendant(path, of: rule.prefix) {
            return rule.category
        }
        return nil
    }

    public func totals(for roots: [FileNode]) -> [StorageCategory: Int64] {
        var totals: [StorageCategory: Int64] = [:]
        func walk(_ node: FileNode, inherited: StorageCategory) {
            let own = category(forPath: node.path, name: node.name, kind: node.kind) ?? inherited
            if node.kind == .file || node.kind == .symlink {
                totals[own, default: 0] += node.allocatedSize
                return
            }
            totals[own, default: 0] += node.ownAllocatedSize
            for child in node.children { walk(child, inherited: own) }
        }
        for root in roots { walk(root, inherited: .other) }
        return totals
    }

    public func bytes(of target: StorageCategory, in node: FileNode, inherited: StorageCategory) -> Int64 {
        let own = category(forPath: node.path, name: node.name, kind: node.kind) ?? inherited
        if node.kind == .file || node.kind == .symlink {
            return own == target ? node.allocatedSize : 0
        }
        var total: Int64 = own == target ? node.ownAllocatedSize : 0
        for child in node.children { total += bytes(of: target, in: child, inherited: own) }
        return total
    }

    public func largestItems(in target: StorageCategory, roots: [FileNode], limit: Int = 30, minimumBytes: Int64 = 1_000_000) -> [CategoryItem] {
        var frontier: [CategoryItem] = roots.compactMap { root in
            let b = bytes(of: target, in: root, inherited: .other)
            return b > 0 ? CategoryItem(node: root, bytes: b, inherited: .other) : nil
        }
        let total = max(frontier.reduce(0) { $0 + $1.bytes }, 1)
        var expanded = 0
        while expanded < 400 {
            guard let index = frontier.indices
                .filter({ shouldExpand(frontier[$0], target: target, total: total) })
                .max(by: { frontier[$0].bytes < frontier[$1].bytes }) else { break }
            let item = frontier.remove(at: index)
            let own = category(forPath: item.node.path, name: item.node.name, kind: item.node.kind) ?? item.inherited
            for child in item.node.children {
                let b = bytes(of: target, in: child, inherited: own)
                if b >= minimumBytes { frontier.append(CategoryItem(node: child, bytes: b, inherited: own)) }
            }
            expanded += 1
        }
        return Array(frontier.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    private func shouldExpand(_ item: CategoryItem, target: StorageCategory, total: Int64) -> Bool {
        let node = item.node
        guard node.kind == .directory, !node.children.isEmpty else { return false }
        let own = category(forPath: node.path, name: node.name, kind: node.kind) ?? item.inherited
        if own != target || node.parent == nil { return true }
        if rules.contains(where: { $0.prefix == node.path }) { return true }
        return Double(item.bytes) / Double(total) > 0.9
    }
}

public struct CategoryItem: Identifiable, Sendable {
    public var id: UUID { node.id }
    public let node: FileNode
    public let bytes: Int64
    public let inherited: StorageCategory
}
