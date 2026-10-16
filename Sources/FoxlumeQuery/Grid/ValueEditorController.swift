import AppKit
import FoxlumeQueryCore

/// Viewer and editor for one cell, for values too long or too rich for the grid. The modes are chosen by content
/// (see `ValueViewMode.modes`): Text edits the value as today, JSON shows an object or array as a tree, Image previews
/// image and PDF bytes, and Hex dumps binary values (or a text's UTF-8). Only Text mode edits; Set NULL works in any
/// mode. Views are built when their mode is first shown, so a large value only pays for the mode it opens in.
@MainActor
final class ValueEditorController: NSObject {
    /// The sheet on screen, for scripted checks.
    private(set) static weak var presented: ValueEditorController?

    let panel: NSPanel
    let modes: [ValueViewMode]
    private(set) var mode: ValueViewMode
    private let value: CellValue
    private let columnName: String
    let editable: Bool
    /// The value's bytes when the column is binary.
    let binaryData: Data?
    private let imageFormat: ImageFormat?
    private let onSave: ((CellValue) -> Void)?
    private var retainSelf: ValueEditorController?

    private let textScroll: NSScrollView
    let textView: NSTextView
    /// The text view gets the value on first use; until then Save has nothing to save.
    private var isTextLoaded = false
    private var jsonView: JSONTreeView?
    /// The text the JSON tree was built from; the tree is rebuilt when the text changed since.
    private var jsonSource: String?
    private var imageView: ImagePreviewView?
    private var hexScroll: HexDumpScrollView?
    private var hexSource: String?

    private let contentArea = NSView()
    private let segments: NSSegmentedControl
    private let accessories = NSStackView()
    private let searchField: NSSearchField
    private let expandButton: NSButton
    private let collapseButton: NSButton
    private let saveAsButton: NSButton
    private let infoLabel: NSTextField
    private let formatButton: NSButton

    init(column: String, typeName: String = "", value: CellValue, editable: Bool, onSave: ((CellValue) -> Void)?) {
        self.value = value
        self.columnName = column
        self.editable = editable
        self.onSave = onSave
        binaryData = BinaryValue.data(of: value, typeName: typeName)
        (modes, mode) = ValueViewMode.modes(for: value, binary: binaryData)
        imageFormat = binaryData.flatMap(ImageFormat.detect)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = column
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 260)
        textScroll = NSTextView.scrollableTextView()
        textView = textScroll.documentView as? NSTextView ?? NSTextView()
        segments = NSSegmentedControl(labels: modes.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        searchField = NSSearchField()
        expandButton = UI.button("Expand All", target: nil, action: nil)
        collapseButton = UI.button("Collapse All", target: nil, action: nil)
        saveAsButton = UI.button("Save As…", target: nil, action: nil)
        infoLabel = UI.label("", size: 11, color: .secondaryLabelColor)
        formatButton = UI.button("Format JSON", target: nil, action: nil)
        super.init()

        textView.isRichText = false
        textView.font = Theme.monospaced(12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isEditable = editable
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityIdentifier("valueEditor")

        segments.target = self
        segments.action = #selector(segmentChanged(_:))
        segments.setAccessibilityIdentifier("valueViewMode")
        segments.isHidden = modes.count < 2
        searchField.placeholderString = "Filter keys and values"
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        searchField.setAccessibilityIdentifier("jsonSearch")
        for (button, action) in [(expandButton, #selector(expandAll(_:))), (collapseButton, #selector(collapseAll(_:))),
                                 (saveAsButton, #selector(saveAs(_:))), (formatButton, #selector(formatJSON(_:)))] {
            button.target = self
            button.action = action
        }
        accessories.orientation = .horizontal
        accessories.spacing = 8

        let setNull = UI.button("Set NULL", target: self, action: #selector(saveNull(_:)))
        let cancel = UI.button(editable ? "Cancel" : "Close", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = UI.button("Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        setNull.isHidden = !editable
        save.isHidden = !editable

        let toolbar = UI.hstack([segments, UI.flexibleSpace(), accessories], spacing: 8)
        let footer = UI.hstack([infoLabel, UI.flexibleSpace(), formatButton, setNull, cancel, save], spacing: 8)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let root = NSView()
        for view in [toolbar, contentArea, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        // Binary values always get it, for Save As….
        let showsToolbar = modes.count > 1 || binaryData != nil
        toolbar.isHidden = !showsToolbar
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            contentArea.topAnchor.constraint(equalTo: showsToolbar ? toolbar.bottomAnchor : root.topAnchor, constant: showsToolbar ? 8 : 0),
            contentArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: contentArea.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 22),
        ])
        panel.contentView = root
        show(mode)
    }

    func present(in window: NSWindow) {
        retainSelf = self
        Self.presented = self
        window.beginSheet(panel)
        panel.makeFirstResponder(firstResponderView)
    }

    func close() {
        panel.sheetParent?.endSheet(panel)
        retainSelf = nil
    }

    // MARK: Modes

    /// Switches to `newMode` when the value offers it.
    func show(_ newMode: ValueViewMode) {
        guard modes.contains(newMode) else { return }
        mode = newMode
        segments.selectedSegment = modes.firstIndex(of: newMode) ?? 0
        let view: NSView
        switch newMode {
        case .text:
            loadText()
            view = textScroll
        case .json:
            view = prepareJSON()
        case .image:
            view = prepareImage()
        case .hex:
            view = prepareHex()
        }
        contentArea.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentArea.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
        let accessoryViews: [NSView]
        switch newMode {
        case .json: accessoryViews = [searchField, expandButton, collapseButton]
        case .image, .hex: accessoryViews = binaryData == nil ? [] : [saveAsButton]
        case .text: accessoryViews = []
        }
        accessories.setViews(accessoryViews, in: .leading)
        formatButton.isHidden = newMode != .text || !ValueViewMode.mayBeJSON(currentText)
        updateInfo()
        if panel.sheetParent != nil { panel.makeFirstResponder(firstResponderView) }
    }

    private var firstResponderView: NSView {
        switch mode {
        case .text: return textView
        case .json: return jsonView?.outline ?? textView
        case .image: return imageView ?? textView
        case .hex: return hexScroll?.hexView ?? textView
        }
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        if let selected = modes[safe: sender.selectedSegment] { show(selected) }
    }

    /// The value as the text view has it, or would have it once loaded.
    var currentText: String {
        isTextLoaded ? textView.string : initialText
    }

    private var initialText: String {
        value.isAbsent ? "" : value.displayString
    }

    private func loadText() {
        guard !isTextLoaded else { return }
        isTextLoaded = true
        textView.string = initialText
    }

    private func prepareJSON() -> JSONTreeView {
        let tree = jsonView ?? JSONTreeView()
        if jsonView == nil {
            jsonView = tree
            tree.onSelectionChange = { [weak self] _ in self?.updateInfo() }
        }
        let text = currentText
        if jsonSource != text {
            jsonSource = text
            tree.show(JSONTreeDocument(text: text))
            tree.search(searchField.stringValue)
        }
        return tree
    }

    private func prepareImage() -> NSView {
        if let imageView { return imageView }
        guard let data = binaryData, let format = imageFormat else { return NSView() }
        let view = ImagePreviewView(data: data, format: format)
        imageView = view
        return view
    }

    /// The bytes Hex mode shows: the binary value, else the UTF-8 of the current text.
    private func prepareHex() -> HexDumpScrollView {
        if let binaryData {
            if let hexScroll { return hexScroll }
            return makeHexScroll(binaryData)
        }
        let text = currentText
        if let hexScroll, hexSource == text { return hexScroll }
        hexSource = text
        return makeHexScroll(Data(text.utf8))
    }

    private func makeHexScroll(_ data: Data) -> HexDumpScrollView {
        let scroll = HexDumpScrollView(data: data)
        scroll.hexView.onSelectionChange = { [weak self] in self?.updateInfo() }
        hexScroll = scroll
        return scroll
    }

    private func updateInfo() {
        infoLabel.stringValue = info
    }

    /// The footer text for the current mode.
    var info: String {
        switch mode {
        case .text:
            return Self.describe(value, bytes: binaryData)
        case .json:
            guard let tree = jsonView, let document = tree.document else { return "Not a JSON object or array" }
            if tree.outline.selectedRow >= 0, let node = tree.outline.item(atRow: tree.outline.selectedRow) as? JSONTreeNode {
                return node.path
            }
            let size = "\(document.root.kind.rawValue) · \(document.root.summary)"
            if let filter = tree.filter { return size + " · " + (filter.matchCount == 1 ? "1 match" : "\(filter.matchCount.groupedText) matches") }
            return size
        case .image:
            return imageView?.summary ?? ""
        case .hex:
            let count = hexScroll?.hexView.data.count ?? 0
            var text = count == 1 ? "1 byte" : "\(count.groupedText) bytes"
            if let selection = hexScroll?.hexView.selection, !selection.isEmpty {
                text += " · \(selection.count.groupedText) selected at 0x" + String(selection.lowerBound, radix: 16)
            }
            return text
        }
    }

    var jsonTree: JSONTreeView? { jsonView }
    var imagePreview: ImagePreviewView? { imageView }
    var hexView: HexDumpView? { hexScroll?.hexView }

    // MARK: Actions

    @objc private func searchChanged(_ sender: Any?) {
        jsonView?.search(searchField.stringValue)
        updateInfo()
    }

    /// Filters the JSON tree as typing in its search field does.
    func searchJSON(_ text: String) {
        searchField.stringValue = text
        searchChanged(nil)
    }

    @objc private func expandAll(_ sender: Any?) {
        jsonView?.expandAll()
    }

    @objc private func collapseAll(_ sender: Any?) {
        jsonView?.collapseAll()
    }

    @objc private func formatJSON(_ sender: Any?) {
        guard let pretty = Self.prettyJSON(textView.string) else { return NSSound.beep() }
        if textView.isEditable, textView.shouldChangeText(in: NSRange(location: 0, length: (textView.string as NSString).length), replacementString: pretty) {
            textView.string = pretty
            textView.didChangeText()
        } else {
            textView.string = pretty
        }
    }

    /// The name Save As suggests: the column name with the extension of the detected format.
    var suggestedFileName: String {
        let base = columnName.isEmpty ? "value" : columnName.replacingOccurrences(of: "/", with: "-")
        return base + "." + (imageFormat?.fileExtension ?? "bin")
    }

    @objc private func saveAs(_ sender: Any?) {
        guard binaryData != nil else { return NSSound.beep() }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = suggestedFileName
        savePanel.canCreateDirectories = true
        savePanel.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }
            do {
                try self.writeBytes(to: url)
            } catch {
                Alerts.showError(error, title: "Could not save the value", in: self.panel)
            }
        }
    }

    /// Writes the value's original bytes, unchanged.
    func writeBytes(to url: URL) throws {
        guard let binaryData else { throw DatabaseError.unsupported("The value is not binary") }
        try binaryData.write(to: url, options: .atomic)
    }

    @objc private func save(_ sender: Any?) {
        if isTextLoaded { onSave?(.text(textView.string)) }
        close()
    }

    @objc private func saveNull(_ sender: Any?) {
        onSave?(.null)
        close()
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    private static func describe(_ value: CellValue, bytes: Data?) -> String {
        if let bytes { return "\(bytes.count.groupedText) bytes (binary)" }
        switch value {
        case .null: return "NULL"
        case .missing: return "No field"
        case .bytes(let data): return "\(data.count.groupedText) bytes (binary)"
        case .text(let text): return "\(text.count.groupedText) characters"
        case .expression(let sql): return "SQL expression \(sql)"
        }
    }

    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
