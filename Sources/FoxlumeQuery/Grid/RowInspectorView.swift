import AppKit
import FoxlumeQueryCore

/// Side panel listing every column of the selected row, one per line, with its type. Values can be edited in place
/// when the table is editable; edits go through the same path as grid edits.
@MainActor
final class RowInspectorView: NSView {
    struct Field {
        var name: String
        var type: String?
        var value: CellValue?
        var editable: Bool
    }

    /// Called with the data column index and the new value.
    var onEdit: ((Int, CellValue) -> Void)?

    private let titleLabel = UI.label("", size: 12, weight: .semibold)
    private let emptyLabel = UI.label("Select a row to see its values.", size: 12, color: .secondaryLabelColor)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var fields: [Field] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var lastValueWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("rowInspector")
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Column"
        nameColumn.width = 130
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = "Value"
        table.addTableColumn(nameColumn)
        table.addTableColumn(valueColumn)
        table.headerView = nil
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        for view in [titleLabel, scroll, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(title: "Row", fields: [], font: font)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Fills the panel. An empty `fields` list shows `message` (or the default hint) instead.
    func show(title: String, fields: [Field], font: NSFont, message: String? = nil) {
        self.fields = fields
        self.font = font
        titleLabel.stringValue = title
        emptyLabel.stringValue = message ?? "Select a row to see its values."
        emptyLabel.isHidden = !fields.isEmpty
        scroll.isHidden = fields.isEmpty
        table.reloadData()
    }

    fileprivate func commit(_ text: String, row: Int) {
        guard let field = fields[safe: row], field.editable else { return }
        let value: CellValue = text == "NULL" && field.value?.isNull == true ? .null : .text(text)
        if value != field.value { onEdit?(row, value) }
    }
}

extension RowInspectorView: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { fields.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let field = fields[safe: row] else { return nil }
        if tableColumn?.identifier.rawValue == "name" {
            let label = NSTextField(wrappingLabelWithString: "")
            let text = NSMutableAttributedString(string: field.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
            if let type = field.type, !type.isEmpty {
                text.append(NSAttributedString(string: "\n" + type, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            label.attributedStringValue = text
            label.preferredMaxLayoutWidth = (tableColumn?.width ?? 130) - 12
            return padded(label)
        }
        let valueField = NSTextField(wrappingLabelWithString: "")
        valueField.font = font
        valueField.tag = row
        valueField.maximumNumberOfLines = 12
        valueField.lineBreakMode = .byCharWrapping
        valueField.setAccessibilityIdentifier("inspectorValue-\(field.name)")
        switch field.value {
        case nil:
            valueField.stringValue = "DEFAULT"
            valueField.textColor = .tertiaryLabelColor
        case .null?:
            valueField.stringValue = "NULL"
            valueField.textColor = .tertiaryLabelColor
        case .missing?:
            valueField.stringValue = ""
            valueField.placeholderString = "No field"
        case let value?:
            valueField.stringValue = value.displayString
            valueField.textColor = .labelColor
        }
        // Wrapping labels need a width to compute their height for automatic row heights.
        valueField.preferredMaxLayoutWidth = max(80, (tableColumn?.width ?? 180) - 12)
        valueField.isEditable = field.editable
        valueField.isSelectable = true
        valueField.delegate = self
        return padded(valueField)
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
        ])
        return container
    }

    /// Rows grow to fit wrapped values (up to 12 lines) and the type under the column name.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let field = fields[safe: row] else { return 24 }
        let nameWidth = (table.tableColumns.first?.width ?? 130) - 12
        let valueWidth = max(80, (table.tableColumns.last?.width ?? 180) - 12)
        var nameHeight = ("Xy" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).height
        if let type = field.type, !type.isEmpty {
            nameHeight += (type as NSString).boundingRect(with: NSSize(width: nameWidth, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 10)]).height
        }
        let text = field.value?.displayString ?? "DEFAULT"
        let lineHeight = ("Xy" as NSString).size(withAttributes: [.font: font]).height
        let valueHeight = min((text as NSString).boundingRect(with: NSSize(width: valueWidth, height: 10_000), options: [.usesLineFragmentOrigin], attributes: [.font: font]).height, lineHeight * 12)
        return ceil(max(nameHeight, valueHeight, lineHeight)) + 10
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.reloadData()
    }

    override func layout() {
        super.layout()
        // The value column fills the panel; rebuild rows when the width it wraps to changes.
        if let valueColumn = table.tableColumns.last, abs(valueColumn.width - lastValueWidth) > 1 {
            lastValueWidth = valueColumn.width
            table.reloadData()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commit(field.stringValue, row: field.tag)
    }
}
