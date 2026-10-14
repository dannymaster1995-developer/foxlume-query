import AppKit
import FoxlumeQueryCore

/// Multi-line viewer and editor for one cell, for values too long for the grid (JSON, text, SQL).
@MainActor
final class ValueEditorController: NSObject {
    private let panel: NSPanel
    private let textView: NSTextView
    private let onSave: ((CellValue) -> Void)?
    private var retainSelf: ValueEditorController?

    init(column: String, value: CellValue, editable: Bool, onSave: ((CellValue) -> Void)?) {
        self.onSave = onSave
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = column
        panel.minSize = NSSize(width: 360, height: 220)
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as? NSTextView ?? NSTextView()
        super.init()

        textView.isRichText = false
        textView.font = Theme.monospaced(12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isEditable = editable
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = value.isAbsent ? "" : value.displayString
        textView.setAccessibilityIdentifier("valueEditor")

        let info = UI.label(Self.describe(value), size: 11, color: .secondaryLabelColor)
        let format = UI.button("Format JSON", target: self, action: #selector(formatJSON(_:)))
        format.isHidden = Self.prettyJSON(textView.string) == nil
        let setNull = UI.button("Set NULL", target: self, action: #selector(saveNull(_:)))
        let cancel = UI.button(editable ? "Cancel" : "Close", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = UI.button("Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        setNull.isHidden = !editable
        save.isHidden = !editable

        let footer = UI.hstack([info, UI.flexibleSpace(), format, setNull, cancel, save], spacing: 8)
        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        panel.contentView = root
    }

    func present(in window: NSWindow) {
        retainSelf = self
        window.beginSheet(panel)
        panel.makeFirstResponder(textView)
    }

    private func close() {
        panel.sheetParent?.endSheet(panel)
        retainSelf = nil
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

    @objc private func save(_ sender: Any?) {
        onSave?(.text(textView.string))
        close()
    }

    @objc private func saveNull(_ sender: Any?) {
        onSave?(.null)
        close()
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    private static func describe(_ value: CellValue) -> String {
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
