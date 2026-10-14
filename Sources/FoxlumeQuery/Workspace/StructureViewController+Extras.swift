import AppKit
import FoxlumeQueryCore

/// The read-only Check Constraints and Triggers sections, as TablePro's Constraints and Triggers tabs list them.
/// Each loads the first time it is shown.
extension StructureViewController {
    static let checkSection = 4
    static let triggerSection = 5

    /// MySQL before 8.0.16 and MariaDB before 10.2.1 ignore CHECK; the driver then lists nothing.
    var showsCheckConstraints: Bool {
        [.postgresql, .mysql, .mariadb, .duckdb].contains(workspace.kind)
    }

    var showsTriggers: Bool { workspace.schemaObjectKinds.contains(.trigger) }

    func resetExtras() {
        triggers = nil
        checkConstraints = nil
        extrasError = nil
    }

    func renderExtras(_ section: Int) {
        if section == Self.triggerSection {
            guard let triggers else { return loadExtras(section) }
            let showsEnabled = triggers.contains { $0.isEnabled != nil }
            let showsCondition = triggers.contains { $0.condition != nil }
            var names = ["Name", "Timing", "Event", "Level"]
            if showsEnabled { names.append("Enabled") }
            if showsCondition { names.append("Condition") }
            names.append(workspace.kind == .postgresql ? "Function" : "Statement")
            let rows: [[CellValue]] = triggers.map { trigger in
                var row: [CellValue] = [.text(trigger.name), .text(trigger.timing), .text(trigger.events.joined(separator: " OR ")), .text(trigger.orientation)]
                if showsEnabled { row.append(trigger.isEnabled.map { .text($0 ? "YES" : "NO") } ?? .null) }
                if showsCondition { row.append(trigger.condition.map(CellValue.text) ?? .null) }
                row.append(.text(trigger.action))
                return row
            }
            grid.setContent(DataGridContent(columns: names.map { ResultColumn(name: $0) }, rows: rows), localSort: true)
        } else {
            guard let checkConstraints else { return loadExtras(section) }
            let showsColumns = checkConstraints.contains { !$0.columns.isEmpty }
            let showsEnforced = checkConstraints.contains { $0.isEnforced != nil }
            var names = ["Name", "Expression"]
            if showsColumns { names.append("Columns") }
            if showsEnforced { names.append(workspace.kind == .postgresql ? "Validated" : "Enforced") }
            let rows: [[CellValue]] = checkConstraints.map { check in
                var row: [CellValue] = [.text(check.name), .text(check.expression)]
                if showsColumns { row.append(.text(check.columns.joined(separator: ", "))) }
                if showsEnforced { row.append(check.isEnforced.map { .text($0 ? "YES" : "NO") } ?? .null) }
                return row
            }
            grid.setContent(DataGridContent(columns: names.map { ResultColumn(name: $0) }, rows: rows), localSort: true)
        }
    }

    private func loadExtras(_ section: Int) {
        grid.setContent(DataGridContent(columns: [ResultColumn(name: "Name")], rows: []), localSort: true)
        Task {
            do {
                if section == Self.triggerSection {
                    triggers = try await workspace.triggers(of: table)
                } else {
                    checkConstraints = try await workspace.checkConstraints(of: table)
                }
                extrasError = nil
            } catch {
                extrasError = error
                if section == Self.triggerSection { triggers = [] } else { checkConstraints = [] }
            }
            if selectedSection == section { showSection(section) }
        }
    }

    /// The status text of the two sections, or nil for the others.
    func extrasStatus(_ section: Int) -> String? {
        func count(_ n: Int, _ singular: String, _ plural: String) -> String { "\(n) \(n == 1 ? singular : plural)" }
        switch section {
        case Self.triggerSection:
            if let extrasError { return extrasError.localizedDescription }
            return triggers.map { count($0.count, "trigger", "triggers") } ?? "Loading…"
        case Self.checkSection:
            if let extrasError { return extrasError.localizedDescription }
            return checkConstraints.map { count($0.count, "check constraint", "check constraints") } ?? "Loading…"
        default:
            return nil
        }
    }
}
