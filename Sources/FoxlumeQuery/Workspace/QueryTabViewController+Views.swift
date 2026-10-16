import AppKit
import FoxlumeQueryCore

/// What a New View… or Edit View… tab edits.
struct ViewEditorContext {
    enum Mode {
        case create
        case edit
    }

    var mode: Mode
    var view: TableRef
    /// The definition Edit View… started from; its comment is set again when PostgreSQL needs DROP + CREATE.
    var definition: ViewDefinition?
}

/// New View… and Edit View… tabs: a query tab with Save View, which runs the whole script through the usual checks
/// (in one transaction where the engine's DDL is transactional). A run that creates or replaces a view selects it in
/// the sidebar; a PostgreSQL refusal to drop, rename or retype columns offers DROP VIEW + CREATE VIEW instead.
extension QueryTabViewController {
    func viewEditorControls() -> (leading: [NSView], trailing: NSView?) {
        guard let context = viewEditor else { return ([], nil) }
        saveViewButton.setAccessibilityIdentifier("saveView")
        saveViewButton.toolTip = "Run the whole script and select the view in the sidebar"
        let hint = UI.label(viewEditorHint(context), size: 11, color: .tertiaryLabelColor)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.toolTip = hint.stringValue
        hint.setAccessibilityIdentifier("viewEditorHint")
        return ([saveViewButton, UI.separator(vertical: true)], hint)
    }

    private func viewEditorHint(_ context: ViewEditorContext) -> String {
        if context.definition?.isMaterialized == true {
            return "Save View drops and creates the materialized view again; its data is computed again"
        }
        if workspace.viewSQL.runsScriptsInTransaction {
            return "Save View runs the whole script in one transaction"
        }
        return "Save View runs the whole script; \(workspace.kind.displayName) commits each statement on its own"
    }

    /// Runs every statement of the tab; several run in one transaction where a failure can roll the others back.
    @objc func saveView(_ sender: Any?) {
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return NSSound.beep() }
        let count = workspace.queryLanguage.split(text).count
        run(text, transactional: count > 1 && workspace.viewSQL.runsScriptsInTransaction)
    }

    /// Called after every run of a view tab, with the SQL that ran and how it ended.
    func viewRunFinished(sql: String, error: Error?) {
        guard let context = viewEditor else { return }
        if let error {
            guard workspace.kind == .postgresql, ViewSQL.needsRecreate(error),
                  let script = workspace.viewSQL.recreateScript(replacing: sql, definition: context.definition)
            else { return }
            offerRecreate(script)
            return
        }
        guard let created = workspace.viewSQL.createdView(in: sql) else { return }
        viewEditor?.view = created
        onViewSaved?(created)
    }

    /// PostgreSQL cannot drop, rename or retype a view's columns with CREATE OR REPLACE; after a confirmation the tab
    /// holds the DROP + CREATE form (undoable) and runs it in one transaction, through the usual checks.
    private func offerRecreate(_ script: String) {
        let lines = script.components(separatedBy: "\n")
        let preview = lines.prefix(14).joined(separator: "\n") + (lines.count > 14 ? "\n…" : "")
        Alerts.confirm(
            "Drop the view and create it again?",
            detail: "CREATE OR REPLACE VIEW cannot drop, rename or change the type of a view's columns. "
                + "DROP VIEW and CREATE VIEW in one transaction can: views and rules that depend on this view make the DROP fail "
                + "and nothing changes, and grants and column comments on the view are not kept.\n\n" + preview,
            confirmTitle: "Drop and Create",
            destructive: true,
            in: view.window
        ) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.replaceSQL(script, actionName: "Drop and Create View")
            self.run(script, transactional: true)
        }
    }
}
