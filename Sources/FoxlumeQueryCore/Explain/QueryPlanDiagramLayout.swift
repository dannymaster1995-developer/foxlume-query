import CoreGraphics
import Foundation

/// Where every step of a plan goes in the Diagram mode: a top-down tree with the root at the top, one row per depth,
/// each parent centred over its children and every subtree in its own column band, so boxes never overlap.
/// Positions depend only on the plan and the sizes, so the same plan always draws the same way.
public struct QueryPlanDiagramLayout: Sendable {
    public struct Metrics: Sendable {
        public var nodeWidth: CGFloat = 230
        public var lineHeight: CGFloat = 15
        public var titleHeight: CGFloat = 17
        public var padding: CGFloat = 8
        public var horizontalGap: CGFloat = 22
        public var verticalGap: CGFloat = 44
        /// Space around the drawing, so the outer boxes do not touch the edge of the canvas or of an export.
        public var margin: CGFloat = 28

        public init() {}
    }

    public struct Edge: Hashable, Sendable {
        public var child: Int
        public var parent: Int
        /// Top centre of the child.
        public var start: CGPoint
        /// Bottom centre of the parent.
        public var end: CGPoint
    }

    public let metrics: Metrics
    /// Node id to its box, in canvas coordinates with the origin at the top left.
    public let frames: [Int: CGRect]
    /// Node ids in pre-order, the order boxes are drawn.
    public let order: [Int]
    public let edges: [Edge]
    public let size: CGSize

    /// The lines a box shows below its title, which decide its height: object, cost and rows, measured values.
    public static func detailLineCount(of node: QueryPlanNode) -> Int {
        var lines = 0
        if node.objectName != nil || node.index != nil { lines += 1 }
        if node.estimatedTotalCost != nil || node.estimatedRows != nil { lines += 1 }
        if node.actualTotalTime != nil || node.actualRows != nil || node.neverExecuted { lines += 1 }
        return lines
    }

    public static func nodeSize(of node: QueryPlanNode, metrics: Metrics = Metrics()) -> CGSize {
        let lines = CGFloat(detailLineCount(of: node))
        return CGSize(width: metrics.nodeWidth, height: metrics.padding * 2 + metrics.titleHeight + lines * metrics.lineHeight)
    }

    public init(plan: QueryPlan, metrics: Metrics = Metrics()) {
        self.init(root: plan.root, metrics: metrics)
    }

    /// Iterative throughout: a plan can nest deeper than a recursive walk's stack allows on a background thread.
    public init(root: QueryPlanNode, metrics: Metrics = Metrics()) {
        self.metrics = metrics
        // Flatten in pre-order: sizes, depths and child lists by id.
        var sizes: [Int: CGSize] = [:]
        var depths: [Int: Int] = [:]
        var children: [Int: [Int]] = [:]
        var rowHeights: [CGFloat] = []
        var order: [Int] = []
        var stack: [(QueryPlanNode, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            let size = Self.nodeSize(of: node, metrics: metrics)
            sizes[node.id] = size
            depths[node.id] = depth
            children[node.id] = node.children.map(\.id)
            order.append(node.id)
            if depth == rowHeights.count { rowHeights.append(0) }
            rowHeights[depth] = max(rowHeights[depth], size.height)
            for child in node.children.reversed() { stack.append((child, depth + 1)) }
        }

        var rowTops: [CGFloat] = []
        var top = metrics.margin
        for height in rowHeights {
            rowTops.append(top)
            top += height + metrics.verticalGap
        }

        // Bottom up: each subtree gets a band as wide as the wider of its node and its children side by side; the
        // children sit left to right inside it and the node is centred over its first and last child.
        var bandWidth: [Int: CGFloat] = [:]
        var nodeOffset: [Int: CGFloat] = [:]
        var childOffset: [Int: CGFloat] = [:]
        for id in order.reversed() {
            let width = sizes[id]?.width ?? 0
            let kids = children[id] ?? []
            guard !kids.isEmpty else {
                bandWidth[id] = width
                nodeOffset[id] = 0
                continue
            }
            var cursor: CGFloat = 0
            for (index, kid) in kids.enumerated() {
                if index > 0 { cursor += metrics.horizontalGap }
                childOffset[kid] = cursor
                cursor += bandWidth[kid] ?? 0
            }
            func centre(_ kid: Int) -> CGFloat {
                (childOffset[kid] ?? 0) + (nodeOffset[kid] ?? 0) + (sizes[kid]?.width ?? 0) / 2
            }
            var middle = (centre(kids[0]) + centre(kids[kids.count - 1])) / 2
            var band = cursor
            if width > cursor {
                // A node wider than its children: centre the children under it instead.
                let shift = (width - cursor) / 2
                for kid in kids { childOffset[kid, default: 0] += shift }
                middle = width / 2
                band = width
            }
            bandWidth[id] = band
            nodeOffset[id] = middle - width / 2
        }

        // Top down: absolute band edges, then boxes.
        var bandLeft: [Int: CGFloat] = [root.id: metrics.margin]
        var frames: [Int: CGRect] = [:]
        for id in order {
            let left = bandLeft[id] ?? metrics.margin
            let size = sizes[id] ?? .zero
            frames[id] = CGRect(x: left + (nodeOffset[id] ?? 0), y: rowTops[depths[id] ?? 0], width: size.width, height: size.height)
            for kid in children[id] ?? [] { bandLeft[kid] = left + (childOffset[kid] ?? 0) }
        }

        var edges: [Edge] = []
        for id in order {
            guard let parentFrame = frames[id] else { continue }
            for kid in children[id] ?? [] {
                guard let childFrame = frames[kid] else { continue }
                edges.append(Edge(child: kid, parent: id,
                                  start: CGPoint(x: childFrame.midX, y: childFrame.minY),
                                  end: CGPoint(x: parentFrame.midX, y: parentFrame.maxY)))
            }
        }

        self.frames = frames
        self.order = order
        self.edges = edges
        let right = frames.values.map(\.maxX).max() ?? 0
        let bottom = frames.values.map(\.maxY).max() ?? 0
        self.size = CGSize(width: ceil(right + metrics.margin), height: ceil(bottom + metrics.margin))
    }

    /// The node under a point, the last drawn first.
    public func node(at point: CGPoint) -> Int? {
        order.last { frames[$0]?.contains(point) == true }
    }
}
