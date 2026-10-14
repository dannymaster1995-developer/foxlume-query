import AppKit
import FoxlumeQueryCore

/// Scripted commands for Explain, acting on the selected query tab.
///
///     explain                     Query › Explain (⌥⌘E) on the selection or the statement at the caret
///     explainanalyze              Query › Explain Analyze (⌃⌘E); a Safe Mode question stays open for `confirm`
///     explainmenu                 logs whether both menu commands are enabled for the selected tab
///     planstate                   logs the result status, summary, note, visible columns and the outline rows
///     planmode diagram|tree|raw   switches the plan view
///     planmetric selfCost|selfTime
///     planselect 3                selects a step by its position in the plan (pre-order, root is 0)
///     plandetails                 logs the detail pane of the selected step
///     planmenu                    logs the outline's context menu
///     plancopy / plancopynode     copies the raw output or the selected step, and logs the first lines copied
///     querymessage                logs the result area's message text (errors and refusals)
@MainActor
enum ExplainAutoTest {
    static let commands: Set<String> = [
        "explain", "explainanalyze", "explainmenu", "planstate", "planmode", "planmetric", "planselect", "plandetails",
        "planmenu", "plancopy", "plancopynode", "querymessage",
    ]
}

extension AutoTestRunner {
    func performExplain(_ command: String, _ argument: String) async throws {
        guard let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController else {
            throw DatabaseError.unsupported("\(command) needs a query tab")
        }
        let plan = query.planView
        switch command {
        case "explain", "explainanalyze":
            query.focusEditor()
            if command == "explain" { query.explainQuery(nil) } else { query.explainAnalyzeQuery(nil) }
            try await Task.sleep(nanoseconds: 400_000_000)
            // A Safe Mode question leaves nothing running; the script answers it with `confirm`.
            try await waitFor(seconds: 30) { !query.isRunning }
            try await Task.sleep(nanoseconds: 400_000_000)
        case "explainmenu":
            for title in ["Explain", "Explain Analyze"] {
                let item = NSMenuItem(title: title, action: title == "Explain" ? #selector(QueryTabViewController.explainQuery(_:)) : #selector(QueryTabViewController.explainAnalyzeQuery(_:)), keyEquivalent: "")
                let enabled = query.validateMenuItem(item)
                record("  \(title): \(enabled ? "enabled" : "disabled")\(item.toolTip.map { " (\($0))" } ?? "")")
            }
            record("  tab bar control: \(query.explainControl.isHidden ? "hidden" : (query.explainControl is NSPopUpButton ? "pull-down" : "button"))")
        case "planstate":
            record("  status: \(Self.statusText(in: query.view))")
            guard !plan.isHidden, query.explainOutcome != nil else { return record("  plan: not shown") }
            record("  mode: \(plan.mode); summary: \(plan.summary)")
            if let note = plan.note { record("  note: \(note)") }
            record("  columns: " + plan.outlineView.visibleColumnTitles.joined(separator: " | "))
            for row in plan.outlineView.rowDescriptions { record("  | \(row)") }
            record("  selected: \(plan.outlineView.selectedNode.map { "#\($0.id) \($0.operation)" } ?? "none"); details: \(plan.detailView.title)")
        case "planmode":
            plan.setMode(argument == "raw" ? .raw : argument == "diagram" ? .diagram : .tree)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "planmetric":
            guard let metric = QueryPlanMetric(rawValue: argument) else { throw DatabaseError.unsupported("planmetric selfCost|selfTime") }
            plan.setMetric(metric)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "planselect":
            plan.outlineView.select(nodeID: Int(argument) ?? 0)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "plandetails":
            record("  details [\(plan.detailView.title)]: " + plan.detailView.detailText.replacingOccurrences(of: "\n", with: " / "))
        case "planmenu":
            record("  " + plan.outlineView.contextMenuTitles.joined(separator: " | "))
        case "plancopy", "plancopynode":
            NSPasteboard.general.clearContents()
            if command == "plancopy" { plan.copyRaw(nil) } else { plan.outlineView.copyDetails(of: plan.outlineView.selectedNode) }
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            record("  copied \(copied.count) characters: " + copied.components(separatedBy: "\n").prefix(4).joined(separator: " / "))
        case "querymessage":
            record("  message: " + Self.messageText(in: query.view).replacingOccurrences(of: "\n", with: " / "))
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    private static func statusText(in view: NSView) -> String {
        if let field = view as? NSTextField, field.accessibilityIdentifier() == "queryStatus" { return field.stringValue }
        for child in view.subviews {
            let found = statusText(in: child)
            if !found.isEmpty { return found }
        }
        return ""
    }

    private static func messageText(in view: NSView) -> String {
        if let text = view as? NSTextView, text.accessibilityIdentifier() == "queryMessages" { return text.string }
        for child in view.subviews {
            let found = messageText(in: child)
            if !found.isEmpty { return found }
        }
        return ""
    }
}
