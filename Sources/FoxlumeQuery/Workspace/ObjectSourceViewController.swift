import AppKit
import FoxlumeQueryCore
import UniformTypeIdentifiers

/// The read-only, highlighted source of a procedure, function, trigger or type, in a tab of its own (TablePro's
/// object source tab). The text is fetched when the tab opens and again on Reload; the tab is restored after a
/// relaunch from the object's address, never from saved text.
@MainActor
final class ObjectSourceViewController: NSViewController, WorkspaceTabContent {
    let workspace: ConnectionWorkspace
    let object: SchemaObject
    var onStateChange: (() -> Void)?
    /// Edit in Query Tab (and Drop, from the window's menus) go through the window.
    var onCommand: ((SchemaObjectCommand) -> Void)?

    var tabTitle: String { "\(object.kind.label): \(object.qualifiedSignature)" }
    var tabSymbol: String { SidebarViewController.symbol(for: object) }
    var hasUnsavedChanges: Bool { false }

    private let editor = SQLEditorView()
    private let attributesLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let statusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let failureView = NSStackView()
    private let failureDetail = UI.label("", size: 12, color: .secondaryLabelColor)
    private lazy var reloadButton = UI.button("Reload", symbol: "arrow.clockwise", target: self, action: #selector(reload(_:)))
    private lazy var editButton = UI.button("Edit in Query Tab", symbol: "square.and.pencil", target: self, action: #selector(editInQueryTab(_:)))
    private lazy var copyButton = UI.button("Copy", symbol: "doc.on.doc", target: self, action: #selector(copyDefinition(_:)))
    private lazy var saveButton = UI.button("Save As…", symbol: "square.and.arrow.down", target: self, action: #selector(saveAs(_:)))
    private(set) var definitionText: String?
    private(set) var isLoading = false
    private(set) var loadError: Error?

    init(workspace: ConnectionWorkspace, object: SchemaObject) {
        self.workspace = workspace
        self.object = object
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("objectSource")

        let icon = NSImageView(image: Theme.image(tabSymbol, object.kind.label, size: 15) ?? NSImage())
        icon.contentTintColor = SidebarViewController.tint(for: object.kind)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let identity = UI.label(object.qualifiedSignature, size: 13, weight: .semibold)
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identity.toolTip = object.qualifiedSignature
        let readOnly = UI.label("Read Only", size: 11, color: .tertiaryLabelColor)
        reloadButton.toolTip = "Read the definition from the server again"
        let header = UI.hstack([icon, identity, capsule(kindCapsuleText), UI.flexibleSpace(), readOnly, reloadButton], spacing: 8)

        editButton.toolTip = workspace.kind == .postgresql || workspace.kind == .duckdb
            ? "Open the definition in a new query tab, ready to run as CREATE OR REPLACE"
            : "Open a DROP and CREATE script in a new query tab"
        copyButton.toolTip = "Copy the definition"
        saveButton.toolTip = "Save the definition as a .sql file"
        editButton.setAccessibilityIdentifier("objectSourceEdit")
        let toolbar = UI.hstack([editButton, copyButton, saveButton, UI.flexibleSpace(), statusLabel], spacing: 6)

        attributesLabel.stringValue = attributeText
        attributesLabel.isHidden = attributeText.isEmpty
        attributesLabel.lineBreakMode = .byTruncatingTail
        attributesLabel.toolTip = object.tooltip

        let top = NSStackView(views: [header, toolbar, attributesLabel])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false
        for row in [header, toolbar] {
            row.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        }

        editor.isEditable = false
        editor.language = workspace.queryLanguage
        editor.applyFontSize(CGFloat(AppEnvironment.settings.editorFontSize))
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.setAccessibilityIdentifier("objectSourceText")

        let failureTitle = UI.label("Source Unavailable", size: 15, weight: .medium, color: .secondaryLabelColor)
        failureDetail.lineBreakMode = .byWordWrapping
        failureDetail.maximumNumberOfLines = 4
        failureDetail.alignment = .center
        let retry = UI.button("Try Again", target: self, action: #selector(reload(_:)))
        failureView.orientation = .vertical
        failureView.spacing = 8
        failureView.setViews([failureTitle, failureDetail, retry], in: .center)
        failureView.translatesAutoresizingMaskIntoConstraints = false
        failureView.isHidden = true

        root.addSubview(top)
        root.addSubview(editor)
        root.addSubview(failureView)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            editor.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            editor.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            failureView.centerXAnchor.constraint(equalTo: editor.centerXAnchor),
            failureView.centerYAnchor.constraint(equalTo: editor.centerYAnchor),
            failureDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        view = root
        load()
    }

    /// "Function", "Enum Type", "Trigger"…
    private var kindCapsuleText: String {
        if object.kind == .type, let detail = object.detail { return detail.capitalized + " Type" }
        if workspace.kind == .duckdb, object.detail == "table_macro" { return "Table Macro" }
        if workspace.kind == .duckdb { return "Macro" }
        return object.kind.label
    }

    private var attributeText: String {
        var parts: [String] = []
        if let returnType = object.returnType { parts.append("Returns \(returnType)") }
        if object.kind.isRoutine, let language = object.detail, workspace.kind != .duckdb { parts.append("Language \(language)") }
        parts += object.attributes.map { "\($0.label): \($0.value)" }
        return parts.joined(separator: "   ·   ")
    }

    private func capsule(_ text: String) -> NSView {
        let label = UI.label(text, size: 10, weight: .semibold, color: .secondaryLabelColor)
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 4
        box.fillColor = .quaternaryLabelColor
        box.contentViewMargins = NSSize(width: 6, height: 1)
        box.titlePosition = .noTitle
        box.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubviewFilling(label, insets: NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6))
        return box
    }

    // MARK: Loading

    @objc func reload(_ sender: Any?) {
        load()
    }

    /// Fetches first and swaps afterwards, so a failed reload keeps the text already shown.
    private func load() {
        guard !isLoading else { return }
        isLoading = true
        statusLabel.stringValue = "Loading…"
        if definitionText == nil { editor.string = "" }
        updateButtons()
        Task {
            do {
                let definition = try await workspace.definition(of: object)
                let text = workspace.schemaObjectSQL.displayText(definition)
                definitionText = text
                loadError = nil
                editor.string = text
                statusLabel.stringValue = ""
            } catch {
                loadError = error
                if definitionText == nil {
                    failureDetail.stringValue = error.localizedDescription
                    statusLabel.stringValue = ""
                } else {
                    statusLabel.stringValue = "Reload failed: \(error.localizedDescription)"
                }
            }
            isLoading = false
            failureView.isHidden = definitionText != nil || loadError == nil
            editor.isHidden = !failureView.isHidden
            updateButtons()
        }
    }

    private func updateButtons() {
        let hasText = definitionText != nil
        copyButton.isEnabled = hasText
        saveButton.isEnabled = hasText
        editButton.isEnabled = hasText
        reloadButton.isEnabled = !isLoading
    }

    // MARK: Actions

    @objc func editInQueryTab(_ sender: Any?) {
        onCommand?(.edit(object))
    }

    @objc func copyDefinition(_ sender: Any?) {
        guard let definitionText else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(definitionText, forType: .string)
    }

    @objc func saveAs(_ sender: Any?) {
        guard let definitionText, let window = view.window else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = object.name + ".sql"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try (definitionText + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Alerts.showError(error, title: "Could not save \(url.lastPathComponent)", in: window)
            }
        }
    }
}
