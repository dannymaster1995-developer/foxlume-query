import AppKit
import Testing
@testable import FoxlumeQuery
@testable import FoxlumeQueryCore

/// A three-level plan: Sort over a Hash Join of two scans, with costs so every step has a severity.
private func samplePlan() -> QueryPlan {
    var left = QueryPlanNode(operation: "Seq Scan")
    left.relation = "orders"
    left.estimatedTotalCost = 80
    left.estimatedRows = 1000
    var right = QueryPlanNode(operation: "Index Scan")
    right.relation = "users"
    right.index = "users_pkey"
    right.estimatedTotalCost = 10
    var join = QueryPlanNode(operation: "Hash Join")
    join.estimatedTotalCost = 120
    join.children = [left, right]
    var sort = QueryPlanNode(operation: "Sort")
    sort.estimatedTotalCost = 125
    sort.children = [join]
    return QueryPlan(format: .postgresJSON, root: sort, rawText: "[]")
}

private func sampleGraph() -> ERDiagramGraph {
    let users = TableStructure(table: TableRef(schema: "public", name: "users"), columns: [
        ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
        ColumnInfo(name: "email", dataType: "character varying(255)", isNullable: false),
    ])
    let orders = TableStructure(table: TableRef(schema: "public", name: "orders"), columns: [
        ColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true),
        ColumnInfo(name: "user_id", dataType: "integer", isNullable: false),
    ], foreignKeys: [ForeignKeyInfo(name: "orders_user_fk", columns: ["user_id"], referencedTable: TableRef(schema: "public", name: "users"), referencedColumns: ["id"])])
    return ERDiagramGraph.build(tables: [TableInfo(ref: users.table), TableInfo(ref: orders.table)], structures: [users, orders])
}

extension AppCompletionTests {
    @Suite("Diagrams")
    @MainActor
    struct DiagramAppTests {
        @Test func planDiagramAndTreeShareTheSelection() throws {
            QueryPlanView.preferredMode = .diagram
            let view = QueryPlanView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
            let plan = samplePlan()
            let request = try ExplainRequest.make(kind: .postgresql, serverVersion: "18.0", statement: "SELECT 1", mode: .plan, readOnly: false)
            view.show(ExplainOutcome(request: request, rawText: "[]", plan: plan, elapsed: 0.01, rolledBack: false))
            view.layoutSubtreeIfNeeded()
            #expect(view.mode == .diagram)
            #expect(view.diagramView.isHidden == false)
            #expect(view.outlineView.isHidden == true)
            #expect(view.diagramView.canvas.selectedID == plan.root.id)
            #expect(view.diagramView.canvas.layout?.frames.count == 4)

            // A click in the diagram selects the step in the tree, which shows its details.
            view.diagramView.canvas.setSelection(2, notify: true)
            #expect(view.outlineView.selectedNode?.id == 2)
            #expect(view.detailView.title == "Seq Scan")
            // And the other way round.
            view.outlineView.select(nodeID: 3)
            #expect(view.diagramView.canvas.selectedID == 3)
            #expect(view.detailView.title == "Index Scan")

            view.setMode(.tree)
            #expect(view.diagramView.isHidden && !view.outlineView.isHidden)
            #expect(view.outlineView.selectedNode?.id == 3)
        }

        @Test func planDiagramExportsAtTwiceItsSize() throws {
            let canvas = QueryPlanDiagramCanvas()
            let plan = samplePlan()
            canvas.show(plan, analysis: QueryPlanAnalysis(plan: plan), metric: .selfCost)
            let size = canvas.exportSize
            #expect(size.width > 200 && size.height > 200)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: name))
                let png = try #require(DiagramImageExporter.pngData(of: canvas, appearance: appearance))
                let rep = try #require(NSBitmapImageRep(data: png))
                #expect(rep.pixelsWide == Int((size.width * 2).rounded(.up)))
                #expect(rep.pixelsHigh == Int((size.height * 2).rounded(.up)))
                // Not blank: the boxes draw something other than the background.
                var colours = Set<String>()
                for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                    if let colour = rep.colorAt(x: x, y: rep.pixelsHigh / 6) { colours.insert(colour.description) }
                }
                #expect(colours.count > 2)
            }
        }

        @Test func erDiagramExportsPNGAndPDFAndCopies() throws {
            let canvas = ERDiagramCanvas()
            let graph = sampleGraph()
            let sizes = ERDiagramCanvas.boxSizes(for: graph, showTypes: true, keysOnly: false)
            let positions = ERDiagramLayout.compute(nodes: graph.tables.map { ERDiagramLayout.Node(id: $0.id, size: sizes[$0.id] ?? .zero) },
                                                    links: graph.relationships.map { ERDiagramLayout.Link(from: $0.from, to: $0.to) })
            canvas.show(graph, positions: positions, sizes: sizes)
            #expect(canvas.route(for: graph.relationships[0]) != nil)
            let size = canvas.exportSize
            #expect(size.width > 300 && size.height > 100)
            let appearance = try #require(NSAppearance(named: .darkAqua))
            let png = try #require(DiagramImageExporter.pngData(of: canvas, appearance: appearance))
            let rep = try #require(NSBitmapImageRep(data: png))
            #expect(rep.pixelsWide == Int((size.width * 2).rounded(.up)))
            #expect(rep.pixelsHigh == Int((size.height * 2).rounded(.up)))
            let pdf = try #require(DiagramImageExporter.pdfData(of: canvas, appearance: appearance))
            #expect(pdf.prefix(4) == Data("%PDF".utf8))
            #expect(DiagramImageExporter.copy(canvas, appearance: appearance))
            #expect(NSPasteboard.general.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == rep.pixelsWide)

            // Hit testing, search and moving a table.
            let usersFrame = try #require(canvas.frame(of: "users"))
            #expect(canvas.table(at: CGPoint(x: usersFrame.midX, y: usersFrame.midY)) == "users")
            #expect(canvas.highlight("ORD") == ["orders"])
            #expect(canvas.highlight("").isEmpty && !canvas.isFiltering)
            var saved: [String: CGPoint]?
            canvas.onPositionsChanged = { saved = $0 }
            canvas.move("users", to: CGPoint(x: -50, y: 900))
            #expect(saved?["users"] == CGPoint(x: 0, y: 900))
            #expect(canvas.frame.height >= 900 + usersFrame.height)
        }

        @Test func hugeDiagramsExportAtAScaleThatFits() {
            #expect(DiagramImageExporter.scale(for: CGSize(width: 1000, height: 800)) == 2)
            let wide = DiagramImageExporter.scale(for: CGSize(width: 15_000, height: 400))
            #expect(15_000 * wide <= DiagramImageExporter.maximumSide + 0.5)
            let big = DiagramImageExporter.scale(for: CGSize(width: 9_000, height: 9_000))
            #expect(9_000 * 9_000 * big * big <= DiagramImageExporter.maximumPixels + 1)
        }

        @Test func zoomLadderSteps() {
            #expect(DiagramZoom.step(from: 1, up: true) == 1.25)
            #expect(DiagramZoom.step(from: 1, up: false) == 0.75)
            #expect(DiagramZoom.step(from: 0.29, up: true) == 0.33)
            #expect(DiagramZoom.step(from: 0.05, up: false) == 0.05)
            #expect(DiagramZoom.step(from: 3, up: true) == 3)
            #expect(DiagramZoom.clamped(.nan) == 1)
            #expect(DiagramZoom.percentText(0.333) == "33%")
        }
    }
}
