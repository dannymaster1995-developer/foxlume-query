import AppKit

/// The find bar shown above a grid by ⌘F: a search field, the match count, previous / next, and for table grids a
/// button that searches every row on the server instead of the loaded page.
@MainActor
final class GridFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let countLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var previousButton = UI.iconButton("chevron.up", tooltip: "Previous Match (⇧⌘G)", target: self, action: #selector(previous(_:)))
    private lazy var nextButton = UI.iconButton("chevron.down", tooltip: "Next Match (⌘G)", target: self, action: #selector(next(_:)))
    private lazy var serverButton = UI.button("Search All Rows", target: self, action: #selector(searchServer(_:)))
    private lazy var doneButton = UI.button("Done", target: self, action: #selector(done(_:)))

    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    /// Set to offer "Search All Rows"; nil hides the button.
    var onSearchServer: ((String) -> Void)? {
        didSet { serverButton.isHidden = onSearchServer == nil }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("gridFindBar")
        field.placeholderString = "Find in results"
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.target = self
        field.action = #selector(fieldChanged(_:))
        field.controlSize = .small
        field.setAccessibilityIdentifier("gridFindField")
        serverButton.controlSize = .small
        serverButton.toolTip = "Filter the table on the server to rows where any column contains the text"
        serverButton.isHidden = true
        doneButton.controlSize = .small
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let stack = UI.hstack([field, countLabel, previousButton, nextButton, UI.flexibleSpace(), serverButton, doneButton], spacing: 6)
        let separator = UI.separator()
        addSubview(stack)
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 260),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setCount(current: Int?, total: Int, searching: Bool) {
        if !searching {
            countLabel.stringValue = ""
        } else if total == 0 {
            countLabel.stringValue = "No matches"
        } else {
            countLabel.stringValue = "\(current.map { "\($0 + 1)" } ?? "–") of \(total.groupedText)"
        }
        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
    }

    @objc private func fieldChanged(_ sender: Any?) {
        onChange?(field.stringValue)
    }

    @objc private func previous(_ sender: Any?) { onPrevious?() }
    @objc private func next(_ sender: Any?) { onNext?() }
    @objc private func done(_ sender: Any?) { onClose?() }

    @objc private func searchServer(_ sender: Any?) {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return NSSound.beep() }
        onSearchServer?(text)
    }

    /// Return finds the next match, Shift-Return the previous one, Escape closes the bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
