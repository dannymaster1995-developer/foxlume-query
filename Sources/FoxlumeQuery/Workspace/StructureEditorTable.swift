import AppKit
import FoxlumeQueryCore

/// The control a structure cell edits with.
enum StructureCellKind {
    case text
    /// Free text with suggestions, such as the type picker.
    case combo([String])
    case check
    case popup([String])
    /// Shown, never edited.
    case label
}

enum StructureCellValue: Equatable {
    case text(String)
    case flag(Bool)

    var text: String {
        if case .text(let value) = self { return value }
        return ""
    }

    var flag: Bool {
        if case .flag(let value) = self { return value }
        return false
    }
}

struct StructureColumnSpec {
    let key: String
    let title: String
    let width: CGFloat
    let kind: StructureCellKind
    var placeholder: String?
    var toolTip: String?

    init(_ key: String, _ title: String, width: CGFloat, kind: StructureCellKind, placeholder: String? = nil, toolTip: String? = nil) {
        self.key = key
        self.title = title
        self.width = width
        self.kind = kind
        self.placeholder = placeholder
        self.toolTip = toolTip
    }
}

/// A table of structure rows whose cells are real controls. It holds no data: the owner answers through closures
/// and receives edits, so the same table serves the structure editor and Create Table.
@MainActor
final class StructureEditorTable: NSView {
    var rowCount: () -> Int = { 0 }
    var value: (_ row: Int, _ key: String) -> StructureCellValue = { _, _ in .text("") }
    var rowState: (_ row: Int) -> StructureRowState = { _ in .unchanged }
    var cellModified: (_ row: Int, _ key: String) -> Bool = { _, _ in false }
    var cellEditable: (_ row: Int, _ key: String) -> Bool = { _, _ in true }
    var onEdit: ((_ row: Int, _ key: String, _ value: StructureCellValue) -> Void)?
    var onDeleteRows: ((IndexSet) -> Void)?
    var onSelectionChange: (() -> Void)?
    var menuItems: ((IndexSet) -> [NSMenuItem])?
    /// Whether rows can be dragged to another place now; the owner moves them in `onMoveRows`.
    var canMoveRows: () -> Bool = { false }
    /// Rows dropped at `destination`, an index of the list before the move.
    var onMoveRows: ((_ rows: IndexSet, _ destination: Int) -> Void)?
    /// ⌥⌘↑ (-1) or ⌥⌘↓ (+1) on the focused table. Returns false when the owner did not handle it.
    var onMoveKey: ((_ offset: Int) -> Bool)?
    /// Create Table shows every row as new, so it turns the change colors off.
    var showsChangeColors = true

    var isEditable = true {
        didSet { if oldValue != isEditable { reload() } }
    }

    private(set) var specs: [StructureColumnSpec] = []
    let tableView = StructureTableView()
    private let scrollView = NSScrollView()
    private var contextRows: IndexSet?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tableView.owner = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.4)
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = Theme.gridBackground
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        // Items are enabled by the owner, which also explains a disabled one in its tooltip.
        tableView.menu?.autoenablesItems = false
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityIdentifier("structureEditor")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubviewFilling(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setSpecs(_ newSpecs: [StructureColumnSpec]) {
        specs = newSpecs
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }
        for spec in newSpecs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 30
            column.headerToolTip = spec.toolTip
            if case .check = spec.kind { column.headerCell.alignment = .center }
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
    }

    /// Reloads every cell and keeps the selection where it is.
    func reload() {
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        let valid = selection.filteredIndexSet { $0 < tableView.numberOfRows }
        tableView.selectRowIndexes(valid, byExtendingSelection: false)
    }

    var selectedRows: IndexSet { contextRows ?? tableView.selectedRowIndexes }

    private static let rowType = NSPasteboard.PasteboardType("com.foxlume.query.structure-row")
    /// The rows being dragged, set when a drag starts in this table.
    private var draggedRows: IndexSet?

    func select(rows: IndexSet) {
        let valid = rows.filteredIndexSet { $0 >= 0 && $0 < tableView.numberOfRows }
        tableView.selectRowIndexes(valid, byExtendingSelection: false)
        if let first = valid.first { tableView.scrollRowToVisible(first) }
    }

    /// Moves rows as a drop at `destination` does. False when moving is not allowed now.
    @discardableResult
    func moveRows(_ rows: IndexSet, to destination: Int) -> Bool {
        guard isEditable, canMoveRows(), !rows.isEmpty, (0...tableView.numberOfRows).contains(destination) else { return false }
        onMoveRows?(rows, destination)
        return true
    }

    func select(row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Puts the caret in a text cell, for a freshly added row.
    func beginEditing(row: Int, key: String) {
        guard isEditable, let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == key }) else { return }
        select(row: row)
        tableView.scrollColumnToVisible(column)
        guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? StructureCellView else { return }
        cell.focus()
    }

    /// Ends any cell edit in progress so its text reaches the owner before a save or preview.
    func commitEditing() {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.isDescendant(of: self)
        else { return }
        window.makeFirstResponder(tableView)
    }

    fileprivate func commit(from cell: StructureCellView, value: StructureCellValue) {
        let row = tableView.row(for: cell)
        guard row >= 0, let key = cell.key, isEditable else { return }
        guard value != self.value(row, key) else { return }
        onEdit?(row, key, value)
    }

    fileprivate func deleteSelection() {
        guard isEditable, !tableView.selectedRowIndexes.isEmpty else { return NSSound.beep() }
        onDeleteRows?(tableView.selectedRowIndexes)
    }
}

extension StructureEditorTable: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue, let spec = specs.first(where: { $0.key == key }) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("structure.\(Self.kindName(spec.kind)).\(key)")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? StructureCellView) ?? StructureCellView(kind: spec.kind, identifier: identifier)
        cell.table = self
        cell.key = key
        let state = rowState(row)
        let shownState: StructureRowState = showsChangeColors ? state : .unchanged
        let modified = showsChangeColors && state == .modified && cellModified(row, key)
        let editable = isEditable && state != .deleted && cellEditable(row, key)
        cell.configure(value: value(row, key), placeholder: spec.placeholder, state: shownState, modified: modified, editable: editable)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = GridRowView()
        view.isAlternate = row % 2 == 1
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }

    // MARK: Dragging rows

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard isEditable, canMoveRows() else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedRows = rowIndexes
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedRows = nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === tableView, draggedRows != nil else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let rows = draggedRows else { return false }
        draggedRows = nil
        return moveRows(rows, to: row)
    }

    private static func kindName(_ kind: StructureCellKind) -> String {
        switch kind {
        case .text: return "text"
        case .combo: return "combo"
        case .check: return "check"
        case .popup: return "popup"
        case .label: return "label"
        }
    }
}

extension StructureEditorTable: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        if clicked >= 0 {
            contextRows = tableView.selectedRowIndexes.contains(clicked) ? tableView.selectedRowIndexes : IndexSet(integer: clicked)
        } else {
            contextRows = IndexSet()
        }
        (menuItems?(contextRows ?? IndexSet()) ?? []).forEach(menu.addItem)
    }

    /// Menu commands run after the menu closes, so forget the clicked rows on the next turn of the run loop.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.contextRows = nil }
    }
}

/// Delete and Forward Delete remove the selected rows; Return edits the first text cell; ⌥⌘↑ / ⌥⌘↓ move rows.
final class StructureTableView: NSTableView {
    weak var owner: StructureEditorTable?

    /// Handled before the main menu, whose First Page / Last Page share these keys but only apply to the Data view.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if modifiers == [.command, .option], [125, 126].contains(event.keyCode), window?.firstResponder === self,
           let owner, owner.onMoveKey?(event.keyCode == 126 ? -1 : 1) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            owner?.deleteSelection()
            return
        case 36, 76:
            if selectedRow >= 0, let owner, let first = owner.specs.first(where: { if case .text = $0.kind { return true } else { return false } }) {
                owner.beginEditing(row: selectedRow, key: first.key)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

/// One cell: a text field, combo box, checkbox, pop-up or label, tinted by the row's change state.
final class StructureCellView: NSTableCellView, NSTextFieldDelegate, NSComboBoxDelegate {
    weak var table: StructureEditorTable?
    var key: String?
    private let kind: StructureCellKind
    private var control: NSControl
    private var state: StructureRowState = .unchanged
    private var modified = false
    private var shownText = ""

    init(kind: StructureCellKind, identifier: NSUserInterfaceItemIdentifier) {
        self.kind = kind
        switch kind {
        case .text:
            let field = NSTextField(string: "")
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.lineBreakMode = .byTruncatingTail
            field.cell?.isScrollable = true
            field.font = Theme.monospaced(12)
            control = field
        case .label:
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.font = Theme.monospaced(11)
            field.textColor = .secondaryLabelColor
            control = field
        case .combo(let items):
            let combo = NSComboBox()
            combo.addItems(withObjectValues: items)
            combo.numberOfVisibleItems = 14
            combo.completes = true
            combo.isBordered = false
            combo.drawsBackground = false
            combo.focusRingType = .none
            combo.controlSize = .small
            combo.font = Theme.monospaced(12)
            control = combo
        case .check:
            control = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        case .popup(let items):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: items)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.isBordered = false
            control = popup
        }
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        switch kind {
        case .check:
            NSLayoutConstraint.activate([
                control.centerXAnchor.constraint(equalTo: centerXAnchor),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        default:
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        if let field = control as? NSTextField {
            field.delegate = self
            if !(control is NSComboBox) { textField = field }
        }
        control.target = self
        control.action = #selector(controlChanged(_:))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(value: StructureCellValue, placeholder: String?, state: StructureRowState, modified: Bool, editable: Bool) {
        self.state = state
        self.modified = modified
        switch control {
        case let button as NSButton:
            button.state = value.flag ? .on : .off
            button.isEnabled = editable
        case let popup as NSPopUpButton:
            popup.selectItem(withTitle: value.text)
            popup.isEnabled = editable
        case let field as NSTextField:
            shownText = value.text
            field.stringValue = value.text
            field.placeholderString = placeholder
            field.isEditable = editable && !isLabel
            field.isSelectable = !isLabel || !value.text.isEmpty
            (field as? NSComboBox)?.isEnabled = editable
        default:
            break
        }
        toolTip = value.text.count > 30 ? value.text : nil
        refreshColors()
    }

    private var isLabel: Bool {
        if case .label = kind { return true }
        return false
    }

    func focus() {
        guard let field = control as? NSTextField, field.isEditable else { return }
        window?.makeFirstResponder(field)
    }

    @objc private func controlChanged(_ sender: Any?) {
        switch control {
        case let button as NSButton:
            table?.commit(from: self, value: .flag(button.state == .on))
        case let popup as NSPopUpButton:
            table?.commit(from: self, value: .text(popup.titleOfSelectedItem ?? ""))
        case let combo as NSComboBox:
            commitText(combo.stringValue)
        default:
            break
        }
    }

    private func commitText(_ text: String) {
        guard text != shownText else { return }
        shownText = text
        table?.commit(from: self, value: .text(text))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = control as? NSTextField else { return }
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue {
            field.stringValue = shownText
            return
        }
        commitText(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            (control as? NSTextField)?.stringValue = shownText
            control.abortEditing()
            window?.makeFirstResponder(table?.tableView)
            return true
        }
        return false
    }

    /// Picking from the combo list commits right away, as choosing from a menu does.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = control as? NSComboBox, combo.indexOfSelectedItem >= 0,
              let picked = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String
        else { return }
        DispatchQueue.main.async { [weak self] in
            combo.stringValue = picked
            self?.commitText(picked)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        let fill: NSColor?
        switch state {
        case .inserted: fill = Theme.insertedRow
        case .deleted: fill = Theme.deletedRow
        case .modified: fill = modified ? Theme.modifiedCell : nil
        case .unchanged: fill = nil
        }
        layer?.backgroundColor = selected ? nil : fill?.cgColor
        guard let field = control as? NSTextField, !(control is NSComboBox) || state == .deleted else { return }
        if state == .deleted {
            field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: field.font ?? Theme.monospaced(12),
            ])
        } else if !isLabel {
            field.textColor = selected ? .alternateSelectedControlTextColor : Theme.gridText
        } else {
            field.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}
