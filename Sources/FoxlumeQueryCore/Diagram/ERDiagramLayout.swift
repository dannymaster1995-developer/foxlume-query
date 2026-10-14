import CoreGraphics
import Foundation

/// Places the tables of an ER diagram. Tables linked by foreign keys form groups; each group is laid out in layers,
/// referenced tables to the left of the tables that reference them, so most lines run left to right between
/// neighbouring columns. A layer taller than the group is wide wraps into several columns. Tables with no
/// relationship sit in a grid ordered by name, and the groups are packed into rows of a roughly landscape canvas.
///
/// Every step orders by name where nothing else decides, so the same schema always gets the same picture, and boxes
/// never overlap: a column stacks its boxes, columns and blocks never share space.
public enum ERDiagramLayout {
    public struct Node: Hashable, Sendable {
        public var id: String
        public var size: CGSize

        public init(id: String, size: CGSize) {
            self.id = id
            self.size = size
        }
    }

    /// A referencing table and the table it references.
    public struct Link: Hashable, Sendable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct Options: Sendable {
        /// Between columns of a group: room for the lines and their crow's feet.
        public var columnGap: CGFloat = 90
        public var rowGap: CGFloat = 36
        /// Between groups, and around the grid of unrelated tables.
        public var blockGap: CGFloat = 110
        public var gridGap: CGFloat = 40
        public var margin: CGFloat = 40
        /// Width over height the packing aims for.
        public var aspect: CGFloat = 1.6

        public init() {}
    }

    /// Top-left corner of every node.
    public static func compute(nodes: [Node], links: [Link], options: Options = Options()) -> [String: CGPoint] {
        let sorted = nodes.sorted { $0.id < $1.id }
        let sizes = Dictionary(sorted.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        let ids = sorted.map(\.id).filter { sizes[$0] != nil }
        var seen = Set<String>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        let usable = links.filter { $0.from != $0.to && sizes[$0.from] != nil && sizes[$0.to] != nil }

        var neighbours: [String: Set<String>] = [:]
        for link in usable {
            neighbours[link.from, default: []].insert(link.to)
            neighbours[link.to, default: []].insert(link.from)
        }

        // Connected groups, biggest first, then by their first name.
        var assigned = Set<String>()
        var groups: [[String]] = []
        var singles: [String] = []
        for id in uniqueIDs where !assigned.contains(id) {
            guard neighbours[id]?.isEmpty == false else {
                singles.append(id)
                assigned.insert(id)
                continue
            }
            var members: [String] = []
            var queue = [id]
            assigned.insert(id)
            while !queue.isEmpty {
                let current = queue.removeFirst()
                members.append(current)
                for next in (neighbours[current] ?? []).sorted() where !assigned.contains(next) {
                    assigned.insert(next)
                    queue.append(next)
                }
            }
            groups.append(members)
        }
        groups.sort { $0.count != $1.count ? $0.count > $1.count : ($0.min() ?? "") < ($1.min() ?? "") }

        var blocks: [Block] = groups.map { layeredBlock(members: $0, links: usable, sizes: sizes, options: options) }
        if !singles.isEmpty {
            blocks.append(gridBlock(members: singles, sizes: sizes, options: options))
        }
        return pack(blocks, options: options)
    }

    /// Positions that keep what the user arranged: saved tables stay where they were, and tables with no saved
    /// position are laid out among themselves below them.
    public static func merge(saved: [String: CGPoint], nodes: [Node], links: [Link], options: Options = Options()) -> [String: CGPoint] {
        let kept = nodes.filter { saved[$0.id] != nil }
        guard !kept.isEmpty else { return compute(nodes: nodes, links: links, options: options) }
        var result: [String: CGPoint] = [:]
        var bottom = options.margin
        for node in kept {
            // Nothing above or left of the canvas, where it could not be scrolled to.
            let point = saved[node.id] ?? .zero
            let clamped = CGPoint(x: max(0, point.x.isFinite ? point.x : 0), y: max(0, point.y.isFinite ? point.y : 0))
            result[node.id] = clamped
            bottom = max(bottom, clamped.y + node.size.height)
        }
        let fresh = nodes.filter { saved[$0.id] == nil }
        guard !fresh.isEmpty else { return result }
        let freshIDs = Set(fresh.map(\.id))
        let placed = compute(nodes: fresh, links: links.filter { freshIDs.contains($0.from) && freshIDs.contains($0.to) }, options: options)
        for (id, point) in placed {
            result[id] = CGPoint(x: point.x, y: point.y + bottom + options.blockGap - options.margin)
        }
        return result
    }

    // MARK: Blocks

    struct Block {
        /// Top-left corners relative to the block.
        var positions: [String: CGPoint]
        var size: CGSize
    }

    static func layeredBlock(members: [String], links: [Link], sizes: [String: CGSize], options: Options) -> Block {
        let memberSet = Set(members)
        let local = links.filter { memberSet.contains($0.from) && memberSet.contains($0.to) }
        var referenced: [String: Set<String>] = [:]
        var referencing: [String: Set<String>] = [:]
        var neighbours: [String: Set<String>] = [:]
        for link in local {
            referenced[link.from, default: []].insert(link.to)
            referencing[link.to, default: []].insert(link.from)
            neighbours[link.from, default: []].insert(link.to)
            neighbours[link.to, default: []].insert(link.from)
        }

        // A table's layer is one past the deepest table it references; a reference that closes a cycle is ignored.
        // Iterative depth-first walk: a long chain of references must not exhaust a background thread's stack.
        var layer: [String: Int] = [:]
        var onPath = Set<String>()
        for root in members.sorted() where layer[root] == nil {
            var stack: [(id: String, targets: [String], next: Int)] = [(root, (referenced[root] ?? []).sorted(), 0)]
            onPath.insert(root)
            while !stack.isEmpty {
                let top = stack.count - 1
                if stack[top].next < stack[top].targets.count {
                    let target = stack[top].targets[stack[top].next]
                    stack[top].next += 1
                    if layer[target] == nil, !onPath.contains(target) {
                        onPath.insert(target)
                        stack.append((target, (referenced[target] ?? []).sorted(), 0))
                    }
                    continue
                }
                let finished = stack.removeLast()
                onPath.remove(finished.id)
                layer[finished.id] = finished.targets.compactMap { layer[$0].map { $0 + 1 } }.max() ?? 0
            }
        }
        // A lookup table referenced only from far right moves next to its nearest referencing table.
        for id in members.sorted() where (referenced[id] ?? []).isEmpty {
            let referrers = (referencing[id] ?? []).compactMap { layer[$0] }
            if let nearest = referrers.min(), nearest - 1 > (layer[id] ?? 0) {
                layer[id] = nearest - 1
            }
        }

        let layerCount = (layer.values.max() ?? 0) + 1
        var layers: [[String]] = Array(repeating: [], count: layerCount)
        // Breadth-first order from the most connected table keeps neighbours close before any sweep.
        let start = members.sorted { (neighbours[$0]?.count ?? 0, $1) > (neighbours[$1]?.count ?? 0, $0) }.first ?? members[0]
        var visited = Set([start])
        var queue = [start]
        var visitOrder: [String] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            visitOrder.append(current)
            for next in (neighbours[current] ?? []).sorted() where !visited.contains(next) {
                visited.insert(next)
                queue.append(next)
            }
        }
        for id in visitOrder { layers[layer[id] ?? 0].append(id) }

        // Barycentre sweeps: each table moves towards the average position of its neighbours in the layer beside it.
        func positions(of layer: [String]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: layer.enumerated().map { ($0.element, Double($0.offset)) })
        }
        for sweep in 0..<6 {
            let forward = sweep % 2 == 0
            let indices = forward ? Array(1..<max(1, layerCount)) : Array((0..<max(0, layerCount - 1)).reversed())
            for index in indices {
                let fixed = positions(of: layers[forward ? index - 1 : index + 1])
                let current = positions(of: layers[index])
                layers[index].sort { lhs, rhs in
                    let a = barycentre(lhs, neighbours: neighbours, fixed: fixed) ?? current[lhs] ?? 0
                    let b = barycentre(rhs, neighbours: neighbours, fixed: fixed) ?? current[rhs] ?? 0
                    if a != b { return a < b }
                    let ca = current[lhs] ?? 0, cb = current[rhs] ?? 0
                    return ca != cb ? ca < cb : lhs < rhs
                }
            }
        }

        // Wrap layers taller than the group should be into several columns.
        let area = members.reduce(CGFloat(0)) { sum, id in
            let size = sizes[id] ?? .zero
            return sum + (size.width + options.columnGap) * (size.height + options.rowGap)
        }
        let tallest = members.map { sizes[$0]?.height ?? 0 }.max() ?? 0
        let limit = max(tallest, (area / options.aspect).squareRoot())
        var columns: [[String]] = []
        for ids in layers where !ids.isEmpty {
            var column: [String] = []
            var height: CGFloat = 0
            for id in ids {
                let h = sizes[id]?.height ?? 0
                if !column.isEmpty, height + options.rowGap + h > limit {
                    columns.append(column)
                    column = []
                    height = 0
                }
                height += (column.isEmpty ? 0 : options.rowGap) + h
                column.append(id)
            }
            if !column.isEmpty { columns.append(column) }
        }

        // Columns left to right; each table aims for the middle of the tables it links to in the columns already
        // placed, without passing the table above it.
        var positionsByID: [String: CGPoint] = [:]
        var x: CGFloat = 0
        for column in columns {
            let width = column.map { sizes[$0]?.width ?? 0 }.max() ?? 0
            var nextTop: CGFloat = 0
            for id in column {
                let size = sizes[id] ?? .zero
                let placedNeighbours = (neighbours[id] ?? []).sorted().compactMap { neighbour -> CGFloat? in
                    guard let origin = positionsByID[neighbour], let other = sizes[neighbour] else { return nil }
                    return origin.y + other.height / 2
                }
                var top = nextTop
                if !placedNeighbours.isEmpty {
                    let desired = placedNeighbours.reduce(0, +) / CGFloat(placedNeighbours.count) - size.height / 2
                    top = max(nextTop, desired)
                }
                positionsByID[id] = CGPoint(x: x, y: top)
                nextTop = top + size.height + options.rowGap
            }
            x += width + options.columnGap
        }
        return normalized(positionsByID, sizes: sizes)
    }

    static func barycentre(_ id: String, neighbours: [String: Set<String>], fixed: [String: Double]) -> Double? {
        let values = (neighbours[id] ?? []).compactMap { fixed[$0] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func gridBlock(members: [String], sizes: [String: CGSize], options: Options) -> Block {
        let ordered = members.sorted()
        let averageWidth = ordered.reduce(CGFloat(0)) { $0 + (sizes[$1]?.width ?? 0) } / CGFloat(max(1, ordered.count))
        let averageHeight = ordered.reduce(CGFloat(0)) { $0 + (sizes[$1]?.height ?? 0) } / CGFloat(max(1, ordered.count))
        // Enough columns for a landscape grid of boxes that are usually taller than wide.
        let ratio = Double((averageHeight + options.gridGap) / max(1, averageWidth + options.gridGap)) * Double(options.aspect)
        let columnCount = max(1, min(ordered.count, Int((Double(ordered.count) * ratio).squareRoot().rounded(.up))))
        var columnWidths = Array(repeating: CGFloat(0), count: columnCount)
        var rowHeights: [CGFloat] = []
        for (index, id) in ordered.enumerated() {
            let size = sizes[id] ?? .zero
            let column = index % columnCount, row = index / columnCount
            columnWidths[column] = max(columnWidths[column], size.width)
            if row == rowHeights.count { rowHeights.append(0) }
            rowHeights[row] = max(rowHeights[row], size.height)
        }
        var positions: [String: CGPoint] = [:]
        for (index, id) in ordered.enumerated() {
            let column = index % columnCount, row = index / columnCount
            let x = columnWidths[..<column].reduce(0, +) + CGFloat(column) * options.gridGap
            let y = rowHeights[..<row].reduce(0, +) + CGFloat(row) * options.gridGap
            positions[id] = CGPoint(x: x, y: y)
        }
        return normalized(positions, sizes: sizes)
    }

    static func normalized(_ positions: [String: CGPoint], sizes: [String: CGSize]) -> Block {
        guard !positions.isEmpty else { return Block(positions: [:], size: .zero) }
        let minX = positions.values.map(\.x).min() ?? 0
        let minY = positions.values.map(\.y).min() ?? 0
        var shifted: [String: CGPoint] = [:]
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        for (id, point) in positions {
            let moved = CGPoint(x: point.x - minX, y: point.y - minY)
            shifted[id] = moved
            let size = sizes[id] ?? .zero
            maxX = max(maxX, moved.x + size.width)
            maxY = max(maxY, moved.y + size.height)
        }
        return Block(positions: shifted, size: CGSize(width: maxX, height: maxY))
    }

    /// Shelf packing: blocks in order (largest group first, the grid of unrelated tables last) fill rows up to a
    /// width that gives the whole canvas the target aspect.
    static func pack(_ blocks: [Block], options: Options) -> [String: CGPoint] {
        let area = blocks.reduce(CGFloat(0)) { $0 + ($1.size.width + options.blockGap) * ($1.size.height + options.blockGap) }
        let widest = blocks.map(\.size.width).max() ?? 0
        let rowWidth = max(widest, (area * options.aspect).squareRoot())
        var result: [String: CGPoint] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for block in blocks {
            if x > 0, x + block.size.width > rowWidth {
                x = 0
                y += rowHeight + options.blockGap
                rowHeight = 0
            }
            for (id, point) in block.positions {
                result[id] = CGPoint(x: options.margin + x + point.x, y: options.margin + y + point.y)
            }
            x += block.size.width + options.blockGap
            rowHeight = max(rowHeight, block.size.height)
        }
        return result
    }
}
