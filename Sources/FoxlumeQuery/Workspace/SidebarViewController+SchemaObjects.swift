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
        let identifier = NSUserInterfaceItemIdentifier("schemaObject")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? ObjectCellView ?? makeObjectCell(identifier: identifier)
        // Plain strings keep the sidebar's vibrant text colors; an attributed label color draws grey.
        cell.textField?.stringValue = box.label
        cell.textField?.textColor = .labelColor
        cell.detailField.stringValue = box.object.kind == .trigger ? box.object.table ?? "" : ""
        cell.detailField.isHidden = cell.detailField.stringValue.isEmpty
        cell.imageView?.image = Theme.image(Self.symbol(for: box.object), box.object.kind.label)
        cell.imageView?.contentTintColor = Self.tint(for: box.object.kind)
        cell.toolTip = box.object.tooltip
        cell.setAccessibilityLabel("\(box.object.kind.label): \(box.label)")
        configureStar(of: cell, for: sidebarItem(box.object))
        return cell
    }

    func noteCell(_ note: SidebarNote, in outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("schemaObjectNote")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? ObjectCellView ?? makeObjectCell(identifier: identifier)
        cell.detailField.isHidden = true
        cell.textField?.attributedStringValue = NSAttributedString(string: note.text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.singleLine,
        ])
        cell.imageView?.image = nil
        cell.toolTip = note.text
        configureStar(of: cell, for: nil)
        return cell
    }

    /// The same layout as the table rows: a 16-point icon, then the text.
    /// Also used for table rows and the Favourites and Recent rows, which share the star at the end.
    func makeObjectCell(identifier: NSUserInterfaceItemIdentifier) -> ObjectCellView {
        let cell = ObjectCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.font = Theme.monospaced(12)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = cell.detailField
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let star = cell.starButton
        star.translatesAutoresizingMaskIntoConstraints = false
        star.isBordered = false
        star.imagePosition = .imageOnly
        star.setButtonType(.momentaryChange)
        star.target = self
        star.action = #selector(starClicked(_:))
        star.isHidden = true
        cell.addSubview(image)
        cell.addSubview(text)
        cell.addSubview(detail)
        cell.addSubview(star)
        cell.textField = text
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 6),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: star.leadingAnchor, constant: -2),
            detail.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: star.leadingAnchor, constant: -2),
            star.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            star.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 16),
            star.heightAnchor.constraint(equalToConstant: 16),
        ])
        return cell
    }

    // MARK: Expansion

    @objc func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringExpansion, let group = notification.userInfo?["NSObject"] as? Group else { return }
        collapsedGroups.remove(group.title)
        // Favourites and Recent stay as the user left them, across windows and launches.
        if let section = group.section { try? AppEnvironment.favourites.setCollapsed(section, false) }
    }

    @objc func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringExpansion, let group = notification.userInfo?["NSObject"] as? Group else { return }
        collapsedGroups.insert(group.title)
        if let section = group.section { try? AppEnvironment.favourites.setCollapsed(section, true) }
    }

    // MARK: Context menu

    private var menuRow: Int { outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow }

    /// The clicked object, or the object a Favourites row stands for when it is in the browsed schema.
    fileprivate var menuObject: SchemaObject? {
        let item = outline.item(atRow: menuRow)
        return (item as? SchemaObjectBox)?.object ?? (item as? ShortcutBox).flatMap(resolvedObject)
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
            addFavouriteMenuItems(for: sidebarItem(object), to: menu)
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

/// A sidebar row: an icon, the name, small secondary text (a trigger's table, a favourite's database and schema) and
/// a star at the end, shown filled for favourites and hollow while the mouse is over the row.
final class ObjectCellView: NSTableCellView {
    let detailField = NSTextField(labelWithString: "")
    let starButton = NSButton()
    /// Rows that cannot be favourites (notes, Redis databases) never show the star.
    var canStar = false { didSet { updateStar() } }
    var isFavourite = false { didSet { updateStar() } }
    var isHovered = false { didSet { updateStar() } }

    private func updateStar() {
        starButton.isHidden = !canStar || !(isFavourite || isHovered)
        let title = isFavourite ? "Remove from Favourites" : "Add to Favourites"
        starButton.image = Theme.image(isFavourite ? "star.fill" : "star", title)
        starButton.contentTintColor = isFavourite ? .systemYellow : .tertiaryLabelColor
        starButton.toolTip = title
        starButton.setAccessibilityLabel(title)
    }
}
