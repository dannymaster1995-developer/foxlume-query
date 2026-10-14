import AppKit
import FoxlumeQueryCore

/// What a schema object row or group asks the window to do.
enum SchemaObjectCommand {
    case copyDefinition(SchemaObject)
    case edit(SchemaObject)
    case drop(SchemaObject)
    /// A trigger template in a new query tab, for the table when one is known.
    case newTrigger(table: TableRef?)
}

final class SchemaObjectBox: NSObject {
    let object: SchemaObject
    /// The row label: the name, with the signature for overloads.
    let label: String
    init(_ object: SchemaObject, label: String) {
        self.object = object
        self.label = label
    }
}

/// A grey, unselectable row inside an empty group: "No procedures", "Loading…".
final class SidebarNote: NSObject {
    let text: String
    init(_ text: String) { self.text = text }
}

/// Procedures, Functions, Triggers and Types groups below Tables and Views, as TablePro shows them for the browsed
/// schema: collapsed until opened, a routine labeled with its signature only when overloaded, a trigger with its table.
extension SidebarViewController {
    func objectGroups(filter: String) -> [Group] {
        let kinds = workspace.schemaObjectKinds
        guard !kinds.isEmpty else { return [] }
        let all = workspace.schemaObjects
        let labels = SchemaObject.labels(for: all)
        var groups: [Group] = []
        for kind in kinds {
            let objects = all.filter { $0.kind == kind && (filter.isEmpty || $0.searchText.lowercased().contains(filter)) }
            // A filter hides groups without matches; otherwise every group the engine has is shown, even empty.
            if !filter.isEmpty, objects.isEmpty { continue }
            let group = Group(title: kind.title, items: [])
            group.objectKind = kind
            group.objects = objects.map { objectBox(for: $0, label: labels[$0.id] ?? $0.name) }
            if objects.isEmpty {
                if let failure = workspace.schemaObjectFailure(kind) {
                    group.note = SidebarNote(failure.localizedDescription)
                } else {
                    group.note = SidebarNote(workspace.isLoadingSchemaObjects && workspace.schemaObjects.isEmpty ? "Loading…" : "No \(kind.title.lowercased())")
                }
            }
            groups.append(group)
        }
        return groups
    }

    private func objectBox(for object: SchemaObject, label: String) -> SchemaObjectBox {
        if let existing = objectBoxes[object.id], existing.object == object, existing.label == label { return existing }
        let box = SchemaObjectBox(object, label: label)
        objectBoxes[object.id] = box
        return box
    }

    var selectedSchemaObject: SchemaObject? {
        (outline.item(atRow: outline.selectedRow) as? SchemaObjectBox)?.object
    }

    /// Selects an object's row, opening its group.
    func select(_ object: SchemaObject) {
        guard let group = groups.first(where: { $0.objectKind == object.kind }),
              let box = group.objects.first(where: { $0.object.id == object.id }) else { return }
        outline.expandItem(group)
        let row = outline.row(forItem: box)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    func setGroup(_ title: String, expanded: Bool) {
        guard let group = groups.first(where: { $0.title == title }) else { return }
        if expanded { outline.expandItem(group) } else { outline.collapseItem(group) }
    }

    /// Group titles with their rows, as the sidebar shows them, for scripted checks.
    func describeObjectGroups() -> [String] {
        groups.filter { $0.objectKind != nil }.map { group in
            let expanded = outline.isItemExpanded(group)
            let rows = group.objects.map { box in box.object.kind == .trigger ? "\(box.label) [\(box.object.table ?? "")]" : box.label }
            let shown = rows.isEmpty ? (group.note.map { ["(\($0.text))"] } ?? []) : rows
            return "\(group.title) (\(group.objects.count), \(expanded ? "open" : "closed")): " + shown.joined(separator: ", ")
        }
    }

    // MARK: Cells

    static func symbol(for object: SchemaObject) -> String {
        switch object.kind {
        case .procedure: return "curlybraces.square"
        case .function: return "function"
        case .trigger: return "bolt"
        case .type:
            switch object.detail {
            case "enum": return "list.bullet"
            case "composite": return "rectangle.split.3x1"
            case "domain": return "checkmark.seal"
            case "range": return "arrow.left.and.right.square"
            default: return "cube"
            }
        }
    }

    /// One line, cut at the end: long signatures must not wrap inside a row.
    static let singleLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    static func tint(for kind: SchemaObjectKind) -> NSColor {
        switch kind {
        case .procedure, .function: return .systemTeal
        case .trigger: return .systemOrange
        case .type: return .systemIndigo
        }
    }

    func objectCell(_ box: SchemaObjectBox, in outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("table")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeObjectCell(identifier: identifier)
        let font = cell.textField?.font ?? Theme.monospaced(12)
        let text = NSMutableAttributedString(string: box.label, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.singleLine])
        if box.object.kind == .trigger, let table = box.object.table {
            text.append(NSAttributedString(string: "  \(table)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.singleLine]))
        }
        cell.textField?.attributedStringValue = text
        cell.imageView?.image = Theme.image(Self.symbol(for: box.object), box.object.kind.label)
        cell.imageView?.contentTintColor = Self.tint(for: box.object.kind)
        cell.toolTip = box.object.tooltip
        cell.setAccessibilityLabel("\(box.object.kind.label): \(box.label)")
        return cell
    }

    func noteCell(_ note: SidebarNote, in outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("table")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeObjectCell(identifier: identifier)
        cell.textField?.attributedStringValue = NSAttributedString(string: note.text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.singleLine,
        ])
        cell.imageView?.image = nil
        cell.toolTip = note.text
        return cell
    }

    /// The same layout as the table rows: a 16-point icon, then the text.
    private func makeObjectCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.font = Theme.monospaced(12)
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.textField = text
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Expansion

    @objc func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringExpansion, let group = notification.userInfo?["NSObject"] as? Group else { return }
        collapsedGroups.remove(group.title)
    }

    @objc func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringExpansion, let group = notification.userInfo?["NSObject"] as? Group else { return }
        collapsedGroups.insert(group.title)
    }

    // MARK: Context menu

    private var menuRow: Int { outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow }

    fileprivate var menuObject: SchemaObject? {
        (outline.item(atRow: menuRow) as? SchemaObjectBox)?.object
    }

    fileprivate var menuObjectGroup: Group? {
        guard let group = outline.item(atRow: menuRow) as? Group, group.objectKind != nil else { return nil }
        return group
    }

    /// The menu of an object row or object group; false for every other row, which keeps the table menu.
    func addObjectMenuItems(to menu: NSMenu) -> Bool {
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        let canWrite = !workspace.isReadOnly
        if let object = menuObject {
            menu.addItem(item(object.kind == .type ? "Show Definition" : "Show DDL", #selector(menuShowObject(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Copy Name", #selector(menuCopyObjectName(_:))))
            if object.kind.isRoutine, object.arguments != nil {
                menu.addItem(item("Copy with Signature", #selector(menuCopyObjectSignature(_:))))
            } else if object.kind == .type, object.schema != nil {
                menu.addItem(item("Copy Qualified Name", #selector(menuCopyObjectSignature(_:))))
            }
            if object.kind == .trigger, object.table != nil {
                menu.addItem(item("Copy Table Name", #selector(menuCopyObjectTable(_:))))
            }
            menu.addItem(item("Copy Definition", #selector(menuCopyObjectDefinition(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Edit in Query Tab", #selector(menuEditObject(_:))))
            if object.kind == .trigger, canWrite, workspace.schemaObjectSQL.hasTriggerTemplate {
                menu.addItem(item("New Trigger…", #selector(menuNewTrigger(_:))))
            }
            if canWrite, workspace.schemaObjectSQL.canDrop(object) {
                menu.addItem(.separator())
                menu.addItem(item("Drop \(object.kind.label)…", #selector(menuDropObject(_:))))
            }
            menu.addItem(.separator())
            menu.addItem(item("Refresh", #selector(menuRefreshObjects(_:))))
            return true
        }
        if let group = menuObjectGroup {
            if group.objectKind == .trigger, canWrite, workspace.schemaObjectSQL.hasTriggerTemplate {
                menu.addItem(item("New Trigger…", #selector(menuNewTrigger(_:))))
                menu.addItem(.separator())
            }
            menu.addItem(item("Refresh", #selector(menuRefreshObjects(_:))))
            return true
        }
        return false
    }

    @objc private func menuShowObject(_ sender: Any?) {
        if let object = menuObject { onOpenObject?(object) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func menuCopyObjectName(_ sender: Any?) {
        if let object = menuObject { copy(object.name) }
    }

    @objc private func menuCopyObjectSignature(_ sender: Any?) {
        guard let object = menuObject else { return }
        copy([object.schema, object.signatureName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "."))
    }

    @objc private func menuCopyObjectTable(_ sender: Any?) {
        if let table = menuObject?.table { copy(table) }
    }

    @objc private func menuCopyObjectDefinition(_ sender: Any?) {
        if let object = menuObject { onObjectCommand?(.copyDefinition(object)) }
    }

    @objc private func menuEditObject(_ sender: Any?) {
        if let object = menuObject { onObjectCommand?(.edit(object)) }
    }

    @objc private func menuDropObject(_ sender: Any?) {
        if let object = menuObject { onObjectCommand?(.drop(object)) }
    }

    @objc private func menuNewTrigger(_ sender: Any?) {
        let table = menuObject?.table.map { TableRef(schema: workspace.kind.supportsSchemas ? (menuObject?.schema ?? workspace.currentSchema) : nil, name: $0) }
        onObjectCommand?(.newTrigger(table: table))
    }

    @objc private func menuRefreshObjects(_ sender: Any?) {
        workspace.refreshSchemaObjects()
    }
}
