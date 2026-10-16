import AppKit
import FoxlumeQueryCore

/// The editor of one table column beyond plain text, set by the table tab from the table structure.
struct GridColumnEditor: Equatable {
    var kind: CellEditorKind
    var isNullable: Bool
    /// A foreign key of this column alone: editing lists rows of the referenced table.
    var reference: ForeignKeyInfo?

    /// Whether editing opens the panel under the cell (dates, enums, foreign keys); booleans toggle in place.
    var hasPanel: Bool {
        if reference != nil { return true }
        switch kind {
        case .temporal, .choice: return true
        case .text, .boolean: return false
        }
    }
}

/// The panel under a cell being edited: a date picker, or a list of enum labels or referenced rows. The cell's text
/// field keeps the keyboard the whole time (the panel never becomes key), so typing works as in any cell; the panel
/// writes into that field, and Up, Down, Return and Escape typed in the field reach the panel through the grid.
@MainActor
final class GridCellEditorPanel: NSObject {
    static let rowHeight: CGFloat = 22
    static let maximumVisibleRows = 10

    weak var grid: DataGridView?
    let row: Int
    let column: Int
    let editor: GridColumnEditor
    private let window: GridCellEditorWindow
    private let background = NSVisualEffectView()

    // Dates and times.
    private var datePicker: NSDatePicker?
    private var timePicker: NSDatePicker?
    private(set) var temporalKind: TemporalKind?

    // Lists.
    private let list = GridChoiceListView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    /// Every label of an enum; the list shows those matching what was typed.
    private var allChoices: [GridChoiceListView.Choice] = []
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    /// Set once the user typed in the cell; until then the list shows everything.
    private var hasTyped = false

    init(grid: DataGridView, row: Int, column: Int, editor: GridColumnEditor, text: String, font: NSFont) {
        self.grid = grid
        self.row = row
        self.column = column
        self.editor = editor
        window = GridCellEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        window.level = .popUpMenu
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.animationBehavior = .none
        window.setAccessibilityIdentifier("cellEditorPanel")
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        window.contentView = background
        list.font = font
        if editor.reference != nil {
            buildList(nullable: editor.isNullable)
            footer.stringValue = "Loading…"
            search("")
        } else {
            switch editor.kind {
            case .temporal(let kind):
                buildTemporal(kind, text: text)
            case .choice(let labels):
                allChoices = labels.map { GridChoiceListView.Choice(value: $0, label: nil) }
                buildList(nullable: editor.isNullable)
                list.setChoices(allChoices, includesNull: editor.isNullable)
                list.highlight(value: text)
                footer.stringValue = "\(labels.count) value\(labels.count == 1 ? "" : "s")"
            case .text, .boolean:
                break
            }
        }
    }

    var isVisible: Bool { window.isVisible }

    func show(below cellRect: NSRect, in tableView: NSTableView) {
        guard let parent = tableView.window else { return }
        if temporalKind == nil { resizeList() }
        let size = background.fittingSize
        let inWindow = tableView.convert(cellRect, to: nil)
        let onScreen = parent.convertToScreen(inWindow)
        var origin = NSPoint(x: onScreen.minX, y: onScreen.minY - size.height - 2)
        if let screen = parent.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = onScreen.maxY + 2 }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
        }
        window.orderFront(nil)
    }

    func close() {
        searchTask?.cancel()
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    // MARK: Dates and times

    private func buildTemporal(_ kind: TemporalKind, text: String) {
        temporalKind = kind
        var views: [NSView] = []
        let gmt = TimeZone(identifier: "GMT") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = gmt
        if kind.hasDate {
            let picker = GridFirstMouseDatePicker()
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = .yearMonthDay
            picker.timeZone = gmt
            picker.calendar = calendar
            picker.isBezeled = false
            picker.drawsBackground = false
            picker.target = self
            picker.action = #selector(pickerChanged(_:))
            picker.setAccessibilityIdentifier("cellDatePicker")
            datePicker = picker
            views.append(picker)
        }
        if kind.hasTime {
            let picker = GridFirstMouseDatePicker()
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinuteSecond
            picker.timeZone = gmt
            picker.calendar = calendar
            picker.target = self
            picker.action = #selector(pickerChanged(_:))
            picker.setAccessibilityIdentifier("cellTimePicker")
            timePicker = picker
            views.append(picker)
        }
        let now = GridFirstMouseButton(title: kind.hasTime ? "Now" : "Today", target: self, action: #selector(setNow(_:)))
        now.setAccessibilityIdentifier("cellEditorNow")
        var buttons: [NSView] = [now]
        if editor.isNullable {
            let clear = GridFirstMouseButton(title: "NULL", target: self, action: #selector(setNull(_:)))
            clear.toolTip = "Clear the value (NULL)"
            clear.setAccessibilityIdentifier("cellEditorNull")
            buttons.append(clear)
        }
        let done = GridFirstMouseButton(title: "Done", target: self, action: #selector(done(_:)))
        done.setAccessibilityIdentifier("cellEditorDone")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.append(contentsOf: [spacer, done])
        for case let button as NSButton in buttons {
            button.controlSize = .small
            button.bezelStyle = .rounded
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 6
        views.append(row)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        syncPickers(with: text)
    }

    /// The value the pickers start from: the cell's text, or now for an empty or unreadable cell.
    private func temporalValue(_ text: String) -> TemporalText? {
        guard let kind = temporalKind else { return nil }
        return TemporalText.parse(text, kind: kind) ?? TemporalText.current(kind)
    }

    /// Typing in the cell moves the pickers along whenever the text reads as a value.
    private func syncPickers(with text: String) {
        guard let kind = temporalKind else { return }
        let value = TemporalText.parse(text, kind: kind) ?? (text.isEmpty ? TemporalText.current(kind) : nil)
        guard let date = value?.pickerDate else { return }
        datePicker?.dateValue = date
        timePicker?.dateValue = date
    }

    @objc private func pickerChanged(_ sender: NSDatePicker) {
        guard let grid, let base = temporalValue(grid.cellEditorText) else { return }
        let day = datePicker.map { TemporalText.fields(ofPickerDate: $0.dateValue).day }
        // Without a time picker the clock stays as written, so the fraction survives a new day.
        let clock = timePicker.map { TemporalText.fields(ofPickerDate: $0.dateValue).clock } ?? base.clock
        grid.replaceCellEditorText(base.replacing(day: day, clock: clock).text)
    }

    @objc func setNow(_ sender: Any?) {
        guard let kind = temporalKind, let grid else { return }
        let text = TemporalText.current(kind).text
        grid.replaceCellEditorText(text)
        syncPickers(with: text)
    }

    @objc func setNull(_ sender: Any?) {
        grid?.commitCellEditor(value: .null)
    }

    @objc func done(_ sender: Any?) {
        grid?.commitCellEditorText()
    }

    /// Sets the pickers as a click on the calendar or the stepper would. Used by scripted checks.
    func pick(day: TemporalText.Day?, clock: TemporalText.Clock?) {
        if let day, let datePicker {
            let current = TemporalText.fields(ofPickerDate: datePicker.dateValue).clock
            datePicker.dateValue = TemporalText(day: day, clock: current).pickerDate ?? datePicker.dateValue
            pickerChanged(datePicker)
        }
        if let clock, let timePicker {
            let current = TemporalText.fields(ofPickerDate: timePicker.dateValue).day
            timePicker.dateValue = TemporalText(day: current, clock: clock).pickerDate ?? timePicker.dateValue
            pickerChanged(timePicker)
        }
    }

    var pickerSummary: String {
        let day = datePicker.map { TemporalText.fields(ofPickerDate: $0.dateValue).day }.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) }
        let clock = timePicker.map { TemporalText.fields(ofPickerDate: $0.dateValue).clock }.map { String(format: "%02d:%02d:%02d", $0.hour, $0.minute, $0.second) }
        return [day, clock].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Lists

    private func buildList(nullable: Bool) {
        list.onPick = { [weak self] index in self?.pick(listRow: index) }
        list.autoresizingMask = [.width]
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.setAccessibilityIdentifier("cellEditorFooter")
        background.addSubview(scroll)
        background.addSubview(footer)
        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        listHeight = height
        let cellWidth = grid?.cellWidth(column: column) ?? 200
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            height,
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            background.widthAnchor.constraint(equalToConstant: min(max(cellWidth, editor.reference == nil ? 200 : 300), 480)),
        ])
        list.onLayout = { [weak self] in self?.resizeList() }
    }

    private var listHeight: NSLayoutConstraint?

    private func resizeList() {
        let rows = CGFloat(min(max(list.rowCount, 1), Self.maximumVisibleRows))
        listHeight?.constant = rows * Self.rowHeight
        background.layoutSubtreeIfNeeded()
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(list.rowCount) * Self.rowHeight)
        guard window.isVisible else { return }
        // Grow or shrink downwards from the top edge, which sits under the cell.
        let top = window.frame.maxY
        let size = background.fittingSize
        window.setFrame(NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Picks a row of the list as a click does: NULL commits NULL, any other row writes its value and ends editing.
    func pick(listRow index: Int) {
        guard let grid, let entry = list.entry(at: index) else { return }
        switch entry {
        case .null:
            grid.commitCellEditor(value: .null)
        case .choice(let choice):
            grid.replaceCellEditorText(choice.value)
            grid.commitCellEditorText()
        }
    }

    /// Up and Down in the cell move through the list and put the row's value in the cell; false when there is no list.
    func moveHighlight(by offset: Int) -> Bool {
        guard temporalKind == nil, list.rowCount > 0 else { return false }
        list.moveHighlight(by: offset)
        scroll.contentView.scrollToVisible(list.rect(ofRow: list.highlighted ?? 0))
        if case .choice(let choice) = list.highlightedEntry {
            grid?.replaceCellEditorText(choice.value)
        } else if case .null = list.highlightedEntry {
            grid?.replaceCellEditorText("")
        }
        return true
    }

    /// Return with the NULL row highlighted sets NULL; the cell's empty text would mean an empty string.
    var highlightsNull: Bool {
        if case .null = list.highlightedEntry { return true }
        return false
    }

    /// The cell's text changed by typing: filter the labels, search the referenced rows, or move the pickers.
    func cellTextDidChange(_ text: String) {
        if temporalKind != nil { return syncPickers(with: text) }
        hasTyped = true
        if editor.reference != nil {
            scheduleSearch(text)
        } else {
            let needle = text.lowercased()
            let matches = needle.isEmpty ? allChoices : allChoices.filter { $0.value.lowercased().contains(needle) }
            list.setChoices(matches, includesNull: editor.isNullable && needle.isEmpty)
            list.highlight(value: text)
            footer.stringValue = matches.isEmpty ? "No matching values" : "\(matches.count) of \(allChoices.count) values"
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.search(text)
        }
    }

    private func search(_ text: String) {
        guard let grid, let key = editor.reference else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let column = self.column
        let current = grid.cellEditorText
        Task { [weak self] in
            do {
                let rows = try await grid.delegate?.dataGrid(grid, referenceCandidatesForColumn: column, matching: text) ?? []
                guard let self, generation == self.searchGeneration else { return }
                self.list.setChoices(rows.map { GridChoiceListView.Choice(value: $0.key.displayString, label: $0.label) }, includesNull: self.editor.isNullable && text.isEmpty)
                self.list.highlight(value: current)
                let table = key.referencedTable.name
                if rows.isEmpty {
                    self.footer.stringValue = text.isEmpty ? "“\(table)” has no rows" : "No rows of “\(table)” match"
                } else if rows.count >= ReferenceCandidates.defaultLimit {
                    self.footer.stringValue = "First \(rows.count) rows of “\(table)”; type to search"
                } else {
                    self.footer.stringValue = "\(rows.count) row\(rows.count == 1 ? "" : "s") of “\(table)”"
                }
                self.searchesFinished += 1
            } catch {
                guard let self, generation == self.searchGeneration else { return }
                self.list.setChoices([], includesNull: self.editor.isNullable)
                self.footer.stringValue = error.localizedDescription
                self.searchesFinished += 1
            }
        }
    }

    /// Completed searches, so scripted checks can wait for the list.
    private(set) var searchesFinished = 0

    /// What the list shows, for scripted checks: `NULL | 1 Alpha | [2 Beta]` with the highlighted row in brackets.
    var listSummary: String {
        (0..<list.rowCount).map { index -> String in
            let text: String
            switch list.entry(at: index) {
            case .null: text = "NULL"
            case .choice(let choice): text = [choice.value, choice.label].compactMap { $0 }.joined(separator: " ")
            case nil: text = ""
            }
            return list.highlighted == index ? "[\(text)]" : text
        }.joined(separator: " | ")
    }

    var footerText: String { footer.stringValue }
}

/// Never key, so the cell keeps the keyboard while the panel is up.
private final class GridCellEditorWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Controls in a panel that is never key take the first click.
private final class GridFirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class GridFirstMouseDatePicker: NSDatePicker {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Plain drawn rows of values (and labels for referenced rows), so nothing in the list can take focus.
final class GridChoiceListView: NSView {
    struct Choice: Equatable {
        /// What a pick writes into the cell.
        var value: String
        /// Shown dimmed beside the value (the referenced row's text column).
        var label: String?
    }

    enum Entry: Equatable {
        case null
        case choice(Choice)
    }

    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var onPick: ((Int) -> Void)?
    var onLayout: (() -> Void)?
    private var entries: [Entry] = []
    private(set) var highlighted: Int?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var rowCount: Int { entries.count }

    func entry(at index: Int) -> Entry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    var highlightedEntry: Entry? { highlighted.flatMap(entry(at:)) }

    func setChoices(_ choices: [Choice], includesNull: Bool) {
        entries = (includesNull ? [.null] : []) + choices.map(Entry.choice)
        highlighted = nil
        onLayout?()
        needsDisplay = true
    }

    /// Highlights the row holding `value` (the cell's current text), if any.
    func highlight(value: String) {
        highlighted = entries.firstIndex { if case .choice(let choice) = $0 { return choice.value == value } else { return false } }
        needsDisplay = true
    }

    func moveHighlight(by offset: Int) {
        guard !entries.isEmpty else { return }
        let current = highlighted ?? (offset > 0 ? -1 : entries.count)
        highlighted = min(max(current + offset, 0), entries.count - 1)
        needsDisplay = true
    }

    func rect(ofRow index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * GridCellEditorPanel.rowHeight, width: bounds.width, height: GridCellEditorPanel.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        for (index, entry) in entries.enumerated() {
            let rowRect = rect(ofRow: index)
            guard rowRect.intersects(dirtyRect) else { continue }
            let selected = index == highlighted
            if selected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
            let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
            let secondary: NSColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
            let textRect = rowRect.insetBy(dx: 12, dy: 0)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            switch entry {
            case .null:
                draw("NULL", in: textRect, attributes: [.font: italic, .foregroundColor: selected ? primary : Theme.nullText, .paragraphStyle: style])
            case .choice(let choice):
                let value = NSAttributedString(string: choice.value, attributes: [.font: font, .foregroundColor: primary, .paragraphStyle: style])
                guard let label = choice.label else {
                    draw(value, in: textRect)
                    continue
                }
                // The key takes what it needs (up to half the row); the label fills the rest.
                let keyWidth = min(ceil(value.size().width) + 12, textRect.width / 2)
                draw(value, in: NSRect(x: textRect.minX, y: textRect.minY, width: keyWidth, height: textRect.height))
                draw(label, in: NSRect(x: textRect.minX + keyWidth, y: textRect.minY, width: textRect.width - keyWidth, height: textRect.height),
                     attributes: [.font: NSFont.systemFont(ofSize: font.pointSize), .foregroundColor: secondary, .paragraphStyle: style])
            }
        }
    }

    private func draw(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        draw(NSAttributedString(string: text, attributes: attributes), in: rect)
    }

    private func draw(_ text: NSAttributedString, in rect: NSRect) {
        let height = text.size().height
        text.draw(with: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / GridCellEditorPanel.rowHeight)
        guard entries.indices.contains(index) else { return }
        highlighted = index
        needsDisplay = true
        onPick?(index)
    }
}
