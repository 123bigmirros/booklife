import Foundation

/// Reconstructs EPUB navigation in reading order. Node identity is positional:
/// publishers may repeat both navigation IDs and destinations.
public struct BookStructure {
    public struct Entry: Equatable {
        public var title: String
        public var href: String
        public var depth: Int
        public init(title: String, href: String, depth: Int) {
            self.title = title; self.href = href; self.depth = depth
        }
    }
    public struct Node: Identifiable {
        public let id: Int
        public let entry: Entry
        public let parent: Int?
        public let depth: Int
        public fileprivate(set) var children: [Int] = []
        public fileprivate(set) var descendantCount = 0
    }
    public struct Placement: Identifiable {
        public let id: Int
        public let x: Double
        public let y: Double
    }
    public struct Layout {
        public let placements: [Placement]
        public let rootY: Double
        public let width: Double
        public let height: Double
    }
    public let nodes: [Node]
    public let roots: [Int]
    private let nodesByHref: [String:[Int]]
    private let nodesByFile: [String:[Int]]
    private let nodesByTitle: [String:[Int]]

    public init(entries: [Entry]) {
        var nodes: [Node] = [], roots: [Int] = [], stack: [Int] = []
        for (id, entry) in entries.enumerated() {
            // A skipped level attaches to the nearest actual ancestor; no
            // invented headings or recursive traversal of untrusted input.
            while let last = stack.last, max(0, nodes[last].entry.depth) >= max(0, entry.depth) { stack.removeLast() }
            let parent = stack.last
            nodes.append(Node(id: id, entry: entry, parent: parent, depth: stack.count))
            if let parent { nodes[parent].children.append(id) } else { roots.append(id) }
            stack.append(id)
        }
        for id in nodes.indices.reversed() {
            if let parent = nodes[id].parent { nodes[parent].descendantCount += nodes[id].descendantCount + 1 }
        }
        self.nodes = nodes; self.roots = roots
        var byHref: [String:[Int]] = [:], byFile: [String:[Int]] = [:], byTitle: [String:[Int]] = [:]
        for node in nodes {
            let href = BookNotesIndex.normalized(node.entry.href)
            byHref[href,default:[]].append(node.id)
            byFile[href.components(separatedBy:"#")[0],default:[]].append(node.id)
            byTitle[node.entry.title,default:[]].append(node.id)
        }
        nodesByHref = byHref; nodesByFile = byFile; nodesByTitle = byTitle
    }

    public func sectionID(href: String?, title: String) -> Int? {
        if let href, !href.isEmpty {
            let normalized = BookNotesIndex.normalized(href)
            let exact = nodesByHref[normalized] ?? []
            let sameTitle = exact.filter { nodes[$0].entry.title == title }
            if sameTitle.count == 1 { return sameTitle[0] }
            if exact.count == 1 { return exact[0] }
            let sameFile = nodesByFile[normalized.components(separatedBy:"#")[0]] ?? []
            let titled = sameFile.filter { nodes[$0].entry.title == title }
            if titled.count == 1 { return titled[0] }
            if sameFile.count == 1 { return sameFile[0] }
        }
        let titled = nodesByTitle[title] ?? []
        return titled.count == 1 ? titled[0] : nil
    }

    public func ancestors(of id: Int) -> [Int] {
        guard nodes.indices.contains(id) else { return [] }
        var result: [Int] = [], parent = nodes[id].parent
        while let id = parent { result.append(id); parent = nodes[id].parent }
        return result.reversed()
    }

    /// A search retains the ancestors of matching headings, regardless of folds.
    public func visible(collapsed: Set<Int>, query: String = "") -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            var included = Set(nodes.filter { $0.entry.title.localizedCaseInsensitiveContains(query) }.map(\.id))
            for node in nodes.reversed() where included.contains(node.id) {
                if let parent = node.parent { included.insert(parent) }
            }
            return nodes.indices.filter { included.contains($0) }
        }
        var hidden = Set<Int>()
        return nodes.compactMap { node in
            if let parent = node.parent, hidden.contains(parent) || collapsed.contains(parent) {
                hidden.insert(node.id); return nil
            }
            return node.id
        }
    }

    /// Parents sit at the midpoint of their visible children. Each leaf owns a
    /// row, so neighboring branches never overlap even with uneven TOC depths.
    public func layout(visible ids: [Int], rowHeight: Double = 88) -> Layout {
        let included = Set(ids)
        var ys: [Int: Double] = [:], leaf = 0
        for id in ids where !nodes[id].children.contains(where: { included.contains($0) }) {
            ys[id] = 24 + Double(leaf) * max(88,rowHeight); leaf += 1
        }
        for id in ids.reversed() {
            let children = nodes[id].children.filter { included.contains($0) }
            if let first = children.first, let last = children.last {
                ys[id] = (ys[first]! + ys[last]!) / 2
            }
        }
        let visibleRoots = roots.filter { included.contains($0) }
        let rootY = visibleRoots.first.flatMap { first in visibleRoots.last.map { (ys[first]! + ys[$0]!) / 2 } } ?? 24
        return Layout(placements: ids.map { Placement(id: $0, x: 24 + Double(nodes[$0].depth + 1) * 268, y: ys[$0]!) },
                      rootY: rootY, width: 24 + Double((ids.map { nodes[$0].depth }.max() ?? -1) + 2) * 268,
                      height: max(112, Double(leaf) * max(88,rowHeight) + 24))
    }
}
