import AppKit
import FoxlumeQueryCore

enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: alpha
        )
    }

    /// A color that follows the user's theme for the current appearance, or `fallback` when the theme leaves the slot unset.
    static func themed(_ slot: ThemeSlot, fallback: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ThemeManager.shared.color(slot, dark: dark) ?? fallback
        }
    }

    // Grid change states, matching the yellow / red / green convention of native database clients.
    static let modifiedCell = themed(.gridModified, fallback: dynamic(light: hex(0xFFF3C4), dark: hex(0x5C4A12)))
    static let deletedRow = themed(.gridDeleted, fallback: dynamic(light: hex(0xFAD4D4), dark: hex(0x5A2326)))
    static let insertedRow = themed(.gridInserted, fallback: dynamic(light: hex(0xD5F2DC), dark: hex(0x1F4A2B)))
    static let nullText = themed(.gridNull, fallback: .tertiaryLabelColor)
    static let rowNumberText = themed(.gridRowNumber, fallback: .secondaryLabelColor)
    static let gridText = themed(.gridText, fallback: .labelColor)
    static let gridBackground = themed(.gridBackground, fallback: .controlBackgroundColor)
    static let gridAlternateRow = themed(.gridAlternateRow, fallback: NSColor.alternatingContentBackgroundColors.count > 1 ? NSColor.alternatingContentBackgroundColors[1] : .controlBackgroundColor)

    // Editor palette.
    static let keyword = themed(.syntaxKeyword, fallback: dynamic(light: hex(0xAD3DA4), dark: hex(0xFC5FA3)))
    static let string = themed(.syntaxString, fallback: dynamic(light: hex(0xC41A16), dark: hex(0xFC6A5D)))
    static let number = themed(.syntaxNumber, fallback: dynamic(light: hex(0x1C00CF), dark: hex(0xD0BF69)))
    static let comment = themed(.syntaxComment, fallback: dynamic(light: hex(0x5D6C79), dark: hex(0x6C7986)))
    static let identifier = themed(.syntaxIdentifier, fallback: dynamic(light: hex(0x3F6E74), dark: hex(0x67B7A4)))
    static let function = themed(.syntaxFunction, fallback: dynamic(light: hex(0x326D74), dark: hex(0xA167E6)))
    static let editorBackground = themed(.editorBackground, fallback: .textBackgroundColor)
    static let editorForeground = themed(.editorForeground, fallback: .textColor)
    static let editorSelection = themed(.editorSelection, fallback: .selectedTextBackgroundColor)
    static let editorLineNumber = themed(.editorLineNumber, fallback: .tertiaryLabelColor)
    static let editorCursor = themed(.editorCursor, fallback: .controlAccentColor)
    static let currentLine = themed(.editorCurrentLine, fallback: dynamic(light: hex(0xECF5FF), dark: hex(0x23252B)))
    static let windowBackdrop = themed(.windowBackdrop, fallback: .windowBackgroundColor)

    static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func color(for color: ConnectionColor) -> NSColor? {
        switch color {
        case .none: return nil
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    static func color(for environment: ConnectionEnvironment) -> NSColor {
        switch environment {
        case .none: return .systemGray
        case .local: return .systemGreen
        case .development: return .systemBlue
        case .staging: return .systemOrange
        case .production: return .systemRed
        }
    }

    static func symbol(for kind: DatabaseKind) -> String {
        switch kind {
        case .postgresql: return "cylinder.split.1x2"
        case .mysql, .mariadb: return "cylinder"
        case .sqlite: return "doc.text"
        case .duckdb: return "bird"
        case .mongodb: return "leaf"
        case .redis: return "memorychip"
        }
    }

    static func symbol(for kind: TableKind) -> String {
        switch kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .materializedView: return "eye.square"
        case .foreignTable: return "link"
        case .systemTable: return "gearshape"
        case .keyspace: return "cylinder"
        }
    }

    static func image(_ symbol: String, _ description: String = "", size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        guard let size else { return image }
        return image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}
