import AppKit
import FoxlumeQueryCore

/// Scripted commands for the plan diagram and the ER diagram.
///
///     erdiagram                   Database › ER Diagram; waits until the diagram is drawn
///     erfocus <table>             a table's "Show in ER Diagram"; waits until drawn
///     erstate                     logs tables, relationships, overlaps, zoom, selection and the status line
///     ersearch <text>             types in the Find Table field (empty clears); ernext jumps to the next match
///     ertypes on|off, erkeys on|off   the Types and Keys Only switches
///     ermove <table> <x> <y>      drags a table to a point and saves the layout
///     erreset                     Reset Layout
///     eropen <table>              double-click: opens the table's data tab
///     ermenu <table>|-            logs the context menu of a table or of the background
///     erexport <name.png|name.pdf>    writes the export into the snapshot folder and logs its size
///     ercopy / plancopyimage      copies the diagram as an image and logs the pasteboard
///     diagramzoom in|out|fit|100|<percent>   zooms the diagram on screen (ER tab or plan diagram)
///     plandiagram                 logs the plan diagram: boxes, canvas size, zoom, selection, details shown
///     plandiagramselect <id>      clicks a step in the plan diagram
///     planexport <name.png>       writes the plan diagram's PNG into the snapshot folder
@MainActor
enum DiagramsAutoTest {
    static let commands: Set<String> = [
        "erdiagram", "erfocus", "erstate", "ersearch", "ernext", "ertypes", "erkeys", "ermove", "erreset", "eropen",
        "ermenu", "erexport", "ercopy", "diagramzoom", "plandiagram", "plandiagramselect", "planexport", "plancopyimage",
    ]
}

extension AutoTestRunner {
    private var erDiagram: ERDiagramViewController? {
        workspace?.tabs.selectedTab?.content as? ERDiagramViewController
    }

    private var planView: QueryPlanView? {
        (workspace?.tabs.selectedTab?.content as? QueryTabViewController)?.planView
    }

    private var snapshotFolder: URL {
        ProcessInfo.processInfo.environment["FOXLUME_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? AppPaths.dataDirectory.appendingPathComponent("snapshots")
    }

    func performDiagrams(_ command: String, _ argument: String) async throws {
        switch command {
        case "erdiagram":
            guard let workspace else { throw DatabaseError.notConnected }
            let item = NSMenuItem(title: "ER Diagram", action: #selector(WorkspaceWindowController.showERDiagram(_:)), keyEquivalent: "")
            record("  menu: \(workspace.validateMenuItem(item) ? "enabled" : "disabled")")
            workspace.showERDiagram(nil)
            try await waitForDiagram()
        case "erfocus":
            guard let workspace, let info = workspace.workspace.tables.first(where: { $0.name == argument }) else {
                throw DatabaseError.unsupported("erfocus <table>")
            }
            workspace.showInERDiagram(info.ref)
            try await waitForDiagram()
            try await Task.sleep(nanoseconds: 400_000_000)
            record("  selected: \(erDiagram?.canvas.selectedID ?? "none"); zoom \(erDiagram?.zoomBar.percentText ?? "-")")
        case "erstate":
            guard let diagram = erDiagram else { return record("  no ER diagram tab") }
            logState(of: diagram)
        case "ersearch":
            erDiagram?.search(argument)
            try await Task.sleep(nanoseconds: 300_000_000)
            record("  status: \(statusLine(of: erDiagram))")
        case "ernext":
            erDiagram?.revealNextMatch()
            try await Task.sleep(nanoseconds: 300_000_000)
            record("  selected: \(erDiagram?.canvas.selectedID ?? "none")")
        case "ertypes", "erkeys":
            guard let diagram = erDiagram else { throw DatabaseError.unsupported("\(command) needs an ER diagram tab") }
            let on = argument != "off"
            diagram.setOptions(showTypes: command == "ertypes" ? on : diagram.canvas.showTypes, keysOnly: command == "erkeys" ? on : diagram.canvas.keysOnly)
            try await waitForDiagram()
        case "ermove":
            let parts = argument.split(separator: " ").map(String.init)
            guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]), let diagram = erDiagram else {
                throw DatabaseError.unsupported("ermove <table> <x> <y>")
            }
            diagram.canvas.move(parts[0], to: CGPoint(x: x, y: y))
            try await Task.sleep(nanoseconds: 200_000_000)
            let saved = diagram.store.positions(for: diagram.scope)
            record("  saved \(saved.count) positions; \(parts[0]) at \(saved[parts[0]].map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "-")")
        case "erreset":
            erDiagram?.resetLayout(nil)
            try await waitForDiagram()
            if let diagram = erDiagram { record("  saved positions: \(diagram.store.positions(for: diagram.scope).count)") }
        case "eropen":
            guard let diagram = erDiagram, let ref = diagram.graph.table(argument)?.ref else { throw DatabaseError.unsupported("eropen <table>") }
            diagram.onOpenTable?(ref)
            try await Task.sleep(nanoseconds: 800_000_000)
            record("  selected tab: \(workspace?.tabs.selectedTab?.content.tabTitle ?? "none")")
        case "ermenu":
            guard let diagram = erDiagram else { throw DatabaseError.unsupported("ermenu needs an ER diagram tab") }
            let items: [NSMenuItem]
            if argument == "-" || argument.isEmpty {
                items = diagram.backgroundMenuForTesting
            } else if let table = diagram.graph.table(argument) {
                items = diagram.canvas.tableMenuItems(table)
            } else {
                throw DatabaseError.unsupported("No table \(argument)")
            }
            record("  " + items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: " | "))
        case "erexport", "planexport":
            let exportable: DiagramExportable? = command == "erexport" ? erDiagram?.canvas : planView?.diagramView.canvas
            guard let exportable else { throw DatabaseError.unsupported("\(command) needs a diagram") }
            let name = argument.isEmpty ? "diagram.png" : argument
            let url = snapshotFolder.appendingPathComponent(name)
            let appearance = (exportable as? NSView)?.effectiveAppearance ?? NSAppearance(named: .aqua)!
            let data = name.hasSuffix(".pdf") ? DiagramImageExporter.pdfData(of: exportable, appearance: appearance) : DiagramImageExporter.pngData(of: exportable, appearance: appearance)
            guard let data else { throw DiagramExportError.renderFailed }
            try data.write(to: url)
            if let rep = NSBitmapImageRep(data: data) {
                record("  wrote \(name): \(rep.pixelsWide)x\(rep.pixelsHigh) px, \(data.count / 1024) KB (diagram \(Int(exportable.exportSize.width))x\(Int(exportable.exportSize.height)) pt)")
            } else {
                record("  wrote \(name): \(data.count / 1024) KB")
            }
        case "ercopy", "plancopyimage":
            NSPasteboard.general.clearContents()
            if command == "ercopy" { erDiagram?.copyImage(nil) } else { planView?.diagramView.copyImage(nil) }
            let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
            let size = NSPasteboard.general.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "-"
            record("  pasteboard: \(types.joined(separator: ", ")); png \(size)")
        case "diagramzoom":
            let scrollView: DiagramScrollView? = erDiagram?.scrollView ?? (planView?.mode == .diagram ? planView?.diagramView.scrollView : nil)
            guard let scrollView else { throw DatabaseError.unsupported("diagramzoom needs a visible diagram") }
            switch argument {
            case "in": scrollView.zoomIn()
            case "out": scrollView.zoomOut()
            case "fit": scrollView.fitToView()
            default: scrollView.zoom(to: (Double(argument) ?? 100) / 100)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            record("  zoom: \(DiagramZoom.percentText(scrollView.magnification))")
        case "plandiagram":
            guard let plan = planView, let layout = plan.diagramView.canvas.layout else { return record("  no plan diagram") }
            let canvas = plan.diagramView.canvas
            let frames = layout.order.compactMap { id in layout.frames[id].map { (String(id), $0) } }
            record("  mode: \(plan.mode); boxes: \(layout.frames.count); arrows: \(layout.edges.count); canvas \(Int(layout.size.width))x\(Int(layout.size.height)); overlaps: \(Self.overlapCount(frames)); zoom \(plan.diagramView.zoomBar.percentText)")
            record("  selected: \(canvas.selectedID.map { "#\($0)" } ?? "none"); tree: \(plan.outlineView.selectedNode.map { "#\($0.id) \($0.operation)" } ?? "none"); details: \(plan.detailView.title)")
        case "plandiagramselect":
            guard let plan = planView, let id = Int(argument) else { throw DatabaseError.unsupported("plandiagramselect <id>") }
            plan.diagramView.canvas.setSelection(id, notify: true)
            try await Task.sleep(nanoseconds: 300_000_000)
            record("  tree: \(plan.outlineView.selectedNode.map { "#\($0.id) \($0.operation)" } ?? "none"); details: \(plan.detailView.title)")
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    private func waitForDiagram() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        try await waitFor(seconds: 60) { self.erDiagram.map { !$0.isBusy } ?? false }
        try await Task.sleep(nanoseconds: 500_000_000)
        if let diagram = erDiagram {
            record("  \(diagram.tabTitle): \(statusLine(of: diagram))\(diagram.loadError.map { " — error: \($0.localizedDescription)" } ?? "")")
        }
    }

    private func statusLine(of diagram: ERDiagramViewController?) -> String {
        diagram?.statusText ?? ""
    }

    private func logState(of diagram: ERDiagramViewController) {
        let canvas = diagram.canvas
        let frames = canvas.graph.tables.compactMap { table in canvas.frame(of: table.id).map { (table.id, $0) } }
        record("  tables: \(canvas.graph.tables.count); relationships: \(canvas.graph.relationships.count); overlaps: \(Self.overlapCount(frames)); canvas \(Int(canvas.frame.width))x\(Int(canvas.frame.height)); zoom \(diagram.zoomBar.percentText)")
        record("  status: \(statusLine(of: diagram)); selected: \(canvas.selectedID ?? "none"); types \(canvas.showTypes ? "on" : "off"), keys only \(canvas.keysOnly ? "on" : "off")")
        for relationship in canvas.graph.relationships.prefix(12) {
            record("  | \(relationship.from)(\(relationship.fromColumns.joined(separator: ","))) -> \(relationship.to)(\(relationship.toColumns.joined(separator: ","))) [\(relationship.cardinality.label)]")
        }
        for table in canvas.graph.tables.prefix(8) {
            let frame = canvas.frame(of: table.id) ?? .zero
            record("  # \(table.name) at (\(Int(frame.minX)), \(Int(frame.minY))) \(Int(frame.width))x\(Int(frame.height)), \(table.columns.count) columns, group \(canvas.graph.groups[table.id].map(String.init) ?? "-")")
        }
    }

    static func overlapCount(_ frames: [(String, CGRect)]) -> Int {
        var count = 0
        for i in frames.indices {
            for j in frames.indices where j > i && frames[i].1.insetBy(dx: 0.5, dy: 0.5).intersects(frames[j].1.insetBy(dx: 0.5, dy: 0.5)) {
                count += 1
            }
        }
        return count
    }
}
