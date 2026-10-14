import AppKit

extension NSView {
    /// Pin all edges to `superview` with the given insets.
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    func addSubviewFilling(_ child: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        addSubview(child)
        child.pinEdges(to: self, insets: insets)
    }
}

enum UI {
    static func label(_ text: String = "", size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector?, bezel: NSButton.BezelStyle = .rounded) -> NSButton {
        let button: NSButton
        if let symbol, let image = Theme.image(symbol, title) {
            button = title.isEmpty ? NSButton(image: image, target: target, action: action) : NSButton(title: title, image: image, target: target, action: action)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        } else {
            button = NSButton(title: title, target: target, action: action)
        }
        button.bezelStyle = bezel
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if title.isEmpty { button.toolTip = symbol }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func iconButton(_ symbol: String, tooltip: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(image: Theme.image(symbol, tooltip) ?? NSImage(), target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        // Thin symbols such as "minus" are only a few points tall; keep every icon button a usable size.
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
        return button
    }

    static func separator(vertical: Bool = false) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return box
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func flexibleSpace() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }
}

enum Alerts {
    static func showError(_ error: Error, title: String = "Something went wrong", in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Asks a yes/no question as a sheet and calls `handler` with the answer.
    static func confirm(_ message: String, detail: String, confirmTitle: String, destructive: Bool = false, in window: NSWindow?, handler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = destructive ? .critical : .warning
        let confirm = alert.addButton(withTitle: confirmTitle)
        if destructive { confirm.hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { handler($0 == .alertFirstButtonReturn) }
        } else {
            handler(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

extension TimeInterval {
    var durationText: String {
        if self < 0.001 { return "<1 ms" }
        if self < 1 { return "\(Int((self * 1000).rounded())) ms" }
        return String(format: "%.2f s", self)
    }
}

extension Int {
    var groupedText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}
