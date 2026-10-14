import CoreGraphics
import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Pairs of rectangles that overlap, allowing them to touch.
private func overlaps(_ rects: [(String, CGRect)]) -> [(String, String)] {
    var found: [(String, String)] = []
    for i in rects.indices {
        for j in rects.indices where j > i {
            if rects[i].1.insetBy(dx: 0.5, dy: 0.5).intersects(rects[j].1.insetBy(dx: 0.5, dy: 0.5)) {
                found.append((rects[i].0, rects[j].0))
            }
        }
    }
    return found
}

/// A plan tree with a fixed shape: `fanOut(depth)` children per node, cycling through operations.
private func syntheticPlan(depth: Int, fanOut: (Int) -> Int) -> QueryPlan {
    var counter = 0
    func make(_ level: Int) -> QueryPlanNode {
        counter += 1
        var node = QueryPlanNode(operation: ["Hash Join", "Seq Scan", "Index Scan", "Sort", "Aggregate"][counter % 5])
        if counter % 3 == 0 { node.relation = "table_\(counter)" }
        if counter % 2 == 0 { node.estimatedTotalCost = Double(counter) * 10; node.estimatedRows = Double(counter) }
        if counter % 4 == 0 { node.actualTotalTime = Double(counter) / 10; node.actualRows = Double(counter) }
        if level < depth {
            node.children = (0..<fanOut(level)).map { _ in make(level + 1) }
        }
        return node
    }
    return QueryPlan(format: .postgresJSON, root: make(0), rawText: "")
}

@Suite struct QueryPlanDiagramLayoutTests {
    @Test func parsedPlanHasOneBoxPerStepAndNoOverlaps() throws {
        let plan = try #require(QueryPlanParser.parse(ExplainFixtures.postgresJoinAnalyze, format: .postgresJSON))
        let layout = QueryPlanDiagramLayout(plan: plan)
        #expect(layout.frames.count == plan.nodeCount)
        #expect(layout.order == plan.allNodes.map(\.id))
        #expect(layout.edges.count == plan.nodeCount - 1)
        #expect(overlaps(layout.frames.map { (String($0.key), $0.value) }).isEmpty)
        // Root on top, every child below its parent, every box inside the canvas.
        let root = try #require(layout.frames[plan.root.id])
        #expect(layout.frames.values.allSatisfy { $0.minY >= root.minY })
        for edge in layout.edges {
            let parent = try #require(layout.frames[edge.parent])
            let child = try #require(layout.frames[edge.child])
            #expect(child.minY > parent.maxY)
            #expect(edge.start == CGPoint(x: child.midX, y: child.minY))
            #expect(edge.end == CGPoint(x: parent.midX, y: parent.maxY))
        }
        let canvas = CGRect(origin: .zero, size: layout.size)
        #expect(layout.frames.values.allSatisfy { canvas.contains($0) })
    }

    @Test func analyzedStepsAreTallerThanBareOnes() {
        var bare = QueryPlanNode(operation: "Result")
        let small = QueryPlanDiagramLayout.nodeSize(of: bare)
        bare.relation = "orders"
        bare.estimatedTotalCost = 12
        bare.actualTotalTime = 0.5
        let tall = QueryPlanDiagramLayout.nodeSize(of: bare)
        #expect(tall.height > small.height)
        #expect(tall.width == small.width)
    }

    @Test func parentsSitCentredOverTheirChildren() throws {
        let plan = syntheticPlan(depth: 2, fanOut: { _ in 3 })
        let layout = QueryPlanDiagramLayout(plan: plan)
        for node in plan.allNodes where !node.children.isEmpty {
            let frame = try #require(layout.frames[node.id])
            let first = try #require(layout.frames[node.children.first!.id])
            let last = try #require(layout.frames[node.children.last!.id])
            #expect(abs(frame.midX - (first.midX + last.midX) / 2) < 0.001)
        }
        // One row per depth: siblings share a top edge.
        let children = plan.root.children.compactMap { layout.frames[$0.id]?.minY }
        #expect(Set(children).count == 1)
    }

    @Test func largePlansStayDeterministicAndApart() {
        // 1 + 4 + 16 + 64 + 256 = 341 steps with uneven heights.
        let plan = syntheticPlan(depth: 4, fanOut: { _ in 4 })
        #expect(plan.nodeCount == 341)
        let started = Date()
        let first = QueryPlanDiagramLayout(plan: plan)
        #expect(Date().timeIntervalSince(started) < 1)
        let second = QueryPlanDiagramLayout(plan: plan)
        #expect(first.frames == second.frames)
        #expect(first.size == second.size)
        #expect(overlaps(first.frames.map { (String($0.key), $0.value) }).isEmpty)
        // A deep chain does not drift sideways.
        let chain = syntheticPlan(depth: 120, fanOut: { _ in 1 })
        #expect(chain.nodeCount == 121)
        let chainLayout = QueryPlanDiagramLayout(plan: chain)
        #expect(Set(chainLayout.frames.values.map(\.minX)).count == 1)
        #expect(overlaps(chainLayout.frames.map { (String($0.key), $0.value) }).isEmpty)
    }

    @Test func hitTestingFindsTheBoxUnderAPoint() throws {
        let plan = syntheticPlan(depth: 2, fanOut: { _ in 2 })
        let layout = QueryPlanDiagramLayout(plan: plan)
        for (id, frame) in layout.frames {
            #expect(layout.node(at: CGPoint(x: frame.midX, y: frame.midY)) == id)
        }
        #expect(layout.node(at: CGPoint(x: 1, y: 1)) == nil)
    }
}

// MARK: ER diagram

private func table(_ name: String, schema: String? = "public", columns: [ColumnInfo], indexes: [IndexInfo] = [], keys: [ForeignKeyInfo] = []) -> (TableInfo, TableStructure) {
    let ref = TableRef(schema: schema, name: name)
    return (TableInfo(ref: ref), TableStructure(table: ref, columns: columns, indexes: indexes, foreignKeys: keys))
}

private func key(_ name: String, _ columns: [String], to table: String, _ referenced: [String], schema: String? = "public") -> ForeignKeyInfo {
    ForeignKeyInfo(name: name, columns: columns, referencedTable: TableRef(schema: schema, name: table), referencedColumns: referenced)
}

/// A schema of `count` tables: chains, a hub with many children, a cycle, and unrelated tables.
private func syntheticSchema(_ count: Int) -> (nodes: [ERDiagramLayout.Node], links: [ERDiagramLayout.Link]) {
    var nodes: [ERDiagramLayout.Node] = []
    var links: [ERDiagramLayout.Link] = []
    for index in 0..<count {
        let id = String(format: "t%03d", index)
        nodes.append(ERDiagramLayout.Node(id: id, size: CGSize(width: 180 + CGFloat(index % 5) * 20, height: 60 + CGFloat(index % 9) * 22)))
        switch index % 10 {
        case 0: break // unrelated or a group root
        case 1, 2, 3: links.append(ERDiagramLayout.Link(from: id, to: String(format: "t%03d", index - 1)))
        case 4, 5, 6, 7: links.append(ERDiagramLayout.Link(from: id, to: "t000"))
        case 8: links.append(ERDiagramLayout.Link(from: id, to: String(format: "t%03d", index - 8)))
        default: if index >= 19 { links.append(ERDiagramLayout.Link(from: String(format: "t%03d", index - 10), to: id)) }
        }
    }
    return (nodes, links)
}

private func frames(_ positions: [String: CGPoint], _ nodes: [ERDiagramLayout.Node]) -> [(String, CGRect)] {
    nodes.compactMap { node in positions[node.id].map { (node.id, CGRect(origin: $0, size: node.size)) } }
}

@Suite struct ERDiagramGraphTests {
    @Test func buildsRelationshipsWithCardinality() {
        let users = table("users", columns: [
            ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
            ColumnInfo(name: "email", dataType: "text", isNullable: false),
        ], indexes: [IndexInfo(name: "users_pkey", columns: ["id"], isUnique: true, isPrimary: true)])
        let orders = table("orders", columns: [
            ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
            ColumnInfo(name: "user_id", dataType: "integer", isNullable: false),
            ColumnInfo(name: "coupon_id", dataType: "integer", isNullable: true),
        ], keys: [key("orders_user_fk", ["user_id"], to: "users", ["id"]), key("orders_coupon_fk", ["coupon_id"], to: "coupons", ["id"], schema: "billing")])
        let profiles = table("profiles", columns: [
            ColumnInfo(name: "user_id", dataType: "integer", isNullable: false, isPrimaryKey: true),
        ], indexes: [IndexInfo(name: "profiles_pkey", columns: ["user_id"], isUnique: true, isPrimary: true)],
           keys: [key("profiles_user_fk", ["user_id"], to: "users", ["id"])])
        let employees = table("employees", columns: [
            ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
            ColumnInfo(name: "manager_id", dataType: "integer", isNullable: true),
        ], indexes: [IndexInfo(name: "employees_manager_key", columns: ["manager_id"], isUnique: true, isPrimary: false)],
           keys: [key("employees_manager_fk", ["manager_id"], to: "employees", ["id"])])
        let lonely = table("settings", columns: [ColumnInfo(name: "k", dataType: "text")])
        let all = [users, orders, profiles, employees, lonely]
        let graph = ERDiagramGraph.build(tables: all.map(\.0), structures: all.map(\.1))

        #expect(graph.tables.map(\.name) == ["employees", "orders", "profiles", "settings", "users"])
        #expect(graph.relationships.map(\.id) == ["employees.employees_manager_fk", "orders.orders_user_fk", "profiles.profiles_user_fk"])
        let byID = Dictionary(uniqueKeysWithValues: graph.relationships.map { ($0.id, $0) })
        #expect(byID["orders.orders_user_fk"]?.cardinality == ERCardinality(isUnique: false, isMandatory: true))
        #expect(byID["profiles.profiles_user_fk"]?.cardinality == ERCardinality(isUnique: true, isMandatory: true))
        #expect(byID["employees.employees_manager_fk"]?.cardinality == ERCardinality(isUnique: true, isMandatory: false))
        #expect(byID["employees.employees_manager_fk"]?.isSelfReference == true)
        // The key into another schema is kept aside, not drawn.
        #expect(graph.externalReferences["orders"]?.map(\.name) == ["orders_coupon_fk"])
        // Markers on columns.
        let ordersTable = graph.table("orders")
        #expect(ordersTable?.columns.map(\.isForeignKey) == [false, true, true])
        #expect(ordersTable?.columns.map(\.isPrimaryKey) == [true, false, false])
        #expect(ordersTable?.keyColumns.map(\.name) == ["id", "user_id", "coupon_id"])
        #expect(graph.table("settings")?.keyColumns.map(\.name) == ["k"])
        // Groups: users, orders and profiles together; a self reference alone makes no group.
        #expect(graph.groups["users"] == graph.groups["orders"])
        #expect(graph.groups["users"] == graph.groups["profiles"])
        #expect(graph.groups["employees"] == nil)
        #expect(graph.groups["settings"] == nil)
    }

    @Test func mysqlKeysIntoAnotherDatabaseStayOutside() {
        let parent = table("parent", schema: nil, columns: [ColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true)])
        let child = table("child", schema: nil, columns: [ColumnInfo(name: "parent_id", dataType: "int")],
                          keys: [key("same_db", ["parent_id"], to: "parent", ["id"], schema: nil),
                                 key("other_db", ["parent_id"], to: "parent", ["id"], schema: "archive")])
        let graph = ERDiagramGraph.build(tables: [parent.0, child.0], structures: [parent.1, child.1])
        #expect(graph.relationships.map(\.name) == ["same_db"])
        #expect(graph.externalReferences["child"]?.map(\.name) == ["other_db"])
    }
}

@Suite struct ERDiagramLayoutTests {
    @Test func noOverlapsAndDeterministic() {
        for count in [1, 2, 7, 40, 120, 200] {
            let schema = syntheticSchema(count)
            let first = ERDiagramLayout.compute(nodes: schema.nodes, links: schema.links)
            #expect(first.count == count)
            #expect(overlaps(frames(first, schema.nodes)).isEmpty, "overlap with \(count) tables")
            // The same input in another order gives the same picture.
            let second = ERDiagramLayout.compute(nodes: schema.nodes.reversed(), links: schema.links.reversed())
            #expect(first == second, "not deterministic with \(count) tables")
            #expect(first.values.allSatisfy { $0.x >= 0 && $0.y >= 0 })
        }
    }

    @Test func connectedTablesSitCloserThanUnrelatedOnes() {
        // 30 small groups (a parent and three children each) and 20 unrelated tables.
        var nodes: [ERDiagramLayout.Node] = []
        var links: [ERDiagramLayout.Link] = []
        for group in 0..<30 {
            let parent = String(format: "g%02d_parent", group)
            nodes.append(ERDiagramLayout.Node(id: parent, size: CGSize(width: 200, height: 80 + CGFloat(group % 4) * 30)))
            for child in 0..<3 {
                let id = String(format: "g%02d_child%d", group, child)
                nodes.append(ERDiagramLayout.Node(id: id, size: CGSize(width: 220, height: 100)))
                links.append(ERDiagramLayout.Link(from: id, to: parent))
            }
        }
        for single in 0..<20 {
            nodes.append(ERDiagramLayout.Node(id: String(format: "single%02d", single), size: CGSize(width: 180, height: 120)))
        }
        let schema = (nodes: nodes, links: links)
        let positions = ERDiagramLayout.compute(nodes: schema.nodes, links: schema.links)
        #expect(overlaps(frames(positions, schema.nodes)).isEmpty)
        let sizes = Dictionary(uniqueKeysWithValues: schema.nodes.map { ($0.id, $0.size) })
        func centre(_ id: String) -> CGPoint {
            let origin = positions[id] ?? .zero, size = sizes[id] ?? .zero
            return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        }
        func distance(_ a: String, _ b: String) -> CGFloat {
            let p = centre(a), q = centre(b)
            return hypot(p.x - q.x, p.y - q.y)
        }
        let linked = schema.links.map { distance($0.from, $0.to) }
        let averageLinked = linked.reduce(0, +) / CGFloat(linked.count)
        let ids = schema.nodes.map(\.id)
        var all: [CGFloat] = []
        for i in ids.indices { for j in ids.indices where j > i { all.append(distance(ids[i], ids[j])) } }
        let averageAll = all.reduce(0, +) / CGFloat(all.count)
        #expect(averageLinked < averageAll / 4)

        // Each group occupies its own region: no table of another group inside a group's bounding box.
        let graphGroups = ERDiagramGraph.connectedGroups(
            tables: ids,
            relationships: schema.links.map { ERDiagramRelationship(name: "\($0.from)_\($0.to)", from: $0.from, fromColumns: [], to: $0.to, toColumns: [], cardinality: ERCardinality(isUnique: false, isMandatory: false)) }
        )
        var boxes: [Int: CGRect] = [:]
        for (id, group) in graphGroups {
            let frame = CGRect(origin: positions[id] ?? .zero, size: sizes[id] ?? .zero)
            boxes[group] = boxes[group].map { $0.union(frame) } ?? frame
        }
        for id in ids {
            let frame = CGRect(origin: positions[id] ?? .zero, size: sizes[id] ?? .zero)
            for (group, box) in boxes where graphGroups[id] != group {
                #expect(!box.insetBy(dx: 1, dy: 1).intersects(frame), "\(id) lies inside group \(group)")
            }
        }
    }

    @Test func referencedTablesGoLeftOfTheirReferrers() {
        let nodes = ["customers", "orders", "order_items", "products"].map { ERDiagramLayout.Node(id: $0, size: CGSize(width: 200, height: 120)) }
        let links = [
            ERDiagramLayout.Link(from: "orders", to: "customers"),
            ERDiagramLayout.Link(from: "order_items", to: "orders"),
            ERDiagramLayout.Link(from: "order_items", to: "products"),
        ]
        let positions = ERDiagramLayout.compute(nodes: nodes, links: links)
        #expect((positions["customers"]?.x ?? 0) < (positions["orders"]?.x ?? 0))
        #expect((positions["orders"]?.x ?? 0) < (positions["order_items"]?.x ?? 0))
        // The lookup table moves next to its only referrer instead of the far left.
        #expect(positions["products"]?.x == positions["orders"]?.x)
    }

    @Test func cyclesAndHubsStayCompact() {
        // A cycle a -> b -> c -> a, and a hub referenced by 60 tables.
        var nodes = ["a", "b", "c"].map { ERDiagramLayout.Node(id: $0, size: CGSize(width: 200, height: 100)) }
        var links = [ERDiagramLayout.Link(from: "a", to: "b"), ERDiagramLayout.Link(from: "b", to: "c"), ERDiagramLayout.Link(from: "c", to: "a")]
        nodes.append(ERDiagramLayout.Node(id: "hub", size: CGSize(width: 200, height: 200)))
        for index in 0..<60 {
            let id = String(format: "leaf%02d", index)
            nodes.append(ERDiagramLayout.Node(id: id, size: CGSize(width: 200, height: 90)))
            links.append(ERDiagramLayout.Link(from: id, to: "hub"))
        }
        let positions = ERDiagramLayout.compute(nodes: nodes, links: links)
        #expect(overlaps(frames(positions, nodes)).isEmpty)
        let box = frames(positions, nodes).reduce(CGRect.null) { $0.union($1.1) }
        // Wrapped into columns rather than one 60-table column.
        #expect(box.height < box.width * 2)
    }

    @Test func savedPositionsWinAndNewTablesGoBelowThem() {
        let nodes = ["a", "b", "c", "d"].map { ERDiagramLayout.Node(id: $0, size: CGSize(width: 200, height: 100)) }
        let saved = ["a": CGPoint(x: 500, y: 40), "b": CGPoint(x: -30, y: 300), "zombie": CGPoint(x: 1, y: 1)]
        let merged = ERDiagramLayout.merge(saved: saved, nodes: nodes, links: [ERDiagramLayout.Link(from: "c", to: "d")])
        #expect(merged["a"] == CGPoint(x: 500, y: 40))
        // Clamped onto the canvas.
        #expect(merged["b"] == CGPoint(x: 0, y: 300))
        #expect(merged["zombie"] == nil)
        #expect((merged["c"]?.y ?? 0) > 400)
        #expect((merged["d"]?.y ?? 0) > 400)
        #expect(overlaps(frames(merged, nodes)).isEmpty)
        #expect(ERDiagramLayout.merge(saved: [:], nodes: nodes, links: []) == ERDiagramLayout.compute(nodes: nodes, links: []))
    }

    @Test func twoHundredTablesLayOutQuickly() {
        let schema = syntheticSchema(200)
        let started = Date()
        _ = ERDiagramLayout.compute(nodes: schema.nodes, links: schema.links)
        #expect(Date().timeIntervalSince(started) < 1)
        // A chain of 400 references deep lays out without running out of stack.
        let chain = (0..<400).map { ERDiagramLayout.Node(id: String(format: "c%03d", $0), size: CGSize(width: 150, height: 60)) }
        let chainLinks = (1..<400).map { ERDiagramLayout.Link(from: String(format: "c%03d", $0), to: String(format: "c%03d", $0 - 1)) }
        let positions = ERDiagramLayout.compute(nodes: chain, links: chainLinks)
        #expect(positions.count == 400)
        #expect(overlaps(frames(positions, chain)).isEmpty)
    }
}

@Suite struct ERDiagramLayoutStoreTests {
    private func makeStore() throws -> (ERDiagramLayoutStore, URL, URL) {
        let folder = TestFiles.url("er-layouts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("er-diagram-layouts.json")
        return (ERDiagramLayoutStore(url: file), file, folder)
    }

    @Test func savesPerDiagramAndClears() throws {
        let (store, file, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = UUID()
        let publicScope = ERDiagramScope(connectionID: connection, database: "foxlume", schema: "public")
        let shopScope = ERDiagramScope(connectionID: connection, database: "foxlume", schema: "shop")
        try store.setPositions(["users": CGPoint(x: 10, y: 20.25), "orders": CGPoint(x: 300, y: CGFloat.infinity)], for: publicScope)
        try store.setPositions(["products": CGPoint(x: 1, y: 2)], for: shopScope)

        let reloaded = ERDiagramLayoutStore(url: file)
        #expect(reloaded.positions(for: publicScope) == ["users": CGPoint(x: 10, y: 20.3)])
        #expect(reloaded.positions(for: shopScope) == ["products": CGPoint(x: 1, y: 2)])
        #expect(reloaded.positions(for: ERDiagramScope(connectionID: UUID(), database: "foxlume", schema: "public")).isEmpty)

        try reloaded.clear(publicScope)
        let afterReset = ERDiagramLayoutStore(url: file)
        #expect(afterReset.positions(for: publicScope).isEmpty)
        #expect(afterReset.positions(for: shopScope).count == 1)
        #expect(afterReset.setAsideFile == nil)
    }

    @Test func damagedFileIsSetAsideAndReadableDiagramsKept() throws {
        let (_, file, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = UUID()
        let damaged = """
            {"version": 1, "diagrams": [
              {"scope": {"connectionID": "\(connection.uuidString)", "database": "foxlume", "schema": "public"},
               "tables": {"users": {"x": 5, "y": 6}, "orders": {"x": "oops"}}},
              {"scope": {"connectionID": 12}, "tables": {"a": {"x": 1, "y": 1}}},
              "not even an object"
            ]}
            """
        try Data(damaged.utf8).write(to: file)
        let store = ERDiagramLayoutStore(url: file)
        let scope = ERDiagramScope(connectionID: connection, database: "foxlume", schema: "public")
        #expect(store.positions(for: scope) == ["users": CGPoint(x: 5, y: 6)])
        let aside = try #require(store.setAsideFile)
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(aside.lastPathComponent.hasPrefix("er-diagram-layouts.unreadable-"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // The next save writes a clean file.
        try store.setPositions(["users": CGPoint(x: 7, y: 8)], for: scope)
        #expect(ERDiagramLayoutStore(url: file).positions(for: scope) == ["users": CGPoint(x: 7, y: 8)])

        // Garbage that is not JSON at all reads as empty and is set aside too, never a crash.
        try Data("\u{0}\u{1}garbage".utf8).write(to: file)
        let garbage = ERDiagramLayoutStore(url: file)
        #expect(garbage.positions(for: scope).isEmpty)
        #expect(garbage.setAsideFile != nil)
    }
}
