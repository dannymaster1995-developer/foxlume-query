import Foundation

/// A color role a theme can set. Themes color content (editor, grid, result area, window backdrop),
/// never native controls, so the app keeps the macOS look.
public enum ThemeSlot: String, Codable, CaseIterable, Sendable {
    case editorBackground
    case editorForeground
    case editorCurrentLine
    case editorSelection
    case editorLineNumber
    case editorCursor
    case syntaxKeyword
    case syntaxString
    case syntaxNumber
    case syntaxComment
    case syntaxIdentifier
    case syntaxFunction
    case gridBackground
    case gridAlternateRow
    case gridText
    case gridNull
    case gridRowNumber
    case gridModified
    case gridInserted
    case gridDeleted
    case windowBackdrop

    public var title: String {
        switch self {
        case .editorBackground: return "Editor Background"
        case .editorForeground: return "Editor Text"
        case .editorCurrentLine: return "Current Line"
        case .editorSelection: return "Selection"
        case .editorLineNumber: return "Line Numbers"
        case .editorCursor: return "Cursor"
        case .syntaxKeyword: return "Keywords"
        case .syntaxString: return "Strings"
        case .syntaxNumber: return "Numbers"
        case .syntaxComment: return "Comments"
        case .syntaxIdentifier: return "Quoted Identifiers"
        case .syntaxFunction: return "Functions"
        case .gridBackground: return "Grid Background"
        case .gridAlternateRow: return "Alternate Rows"
        case .gridText: return "Grid Text"
        case .gridNull: return "NULL Values"
        case .gridRowNumber: return "Row Numbers"
        case .gridModified: return "Modified Cells"
        case .gridInserted: return "New Rows"
        case .gridDeleted: return "Deleted Rows"
        case .windowBackdrop: return "Window Background"
        }
    }
}

public enum ThemeAppearance: String, Codable, Sendable {
    case light
    case dark
}

/// A named set of colors. Slots left out fall back to the system colors of the theme's appearance.
public struct ThemeDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    public var appearance: ThemeAppearance
    /// Hex colors, `#RRGGBB` or `#RRGGBBAA`.
    public var colors: [ThemeSlot: String]
    /// Where the theme came from, for example "VS Code: Dracula Official".
    public var source: String?
    public var isBuiltIn: Bool

    public init(id: String, name: String, author: String = "", appearance: ThemeAppearance, colors: [ThemeSlot: String], source: String? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.author = author
        self.appearance = appearance
        self.colors = colors
        self.source = source
        self.isBuiltIn = isBuiltIn
    }

    enum CodingKeys: String, CodingKey {
        case id, name, author, appearance, colors, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        appearance = try container.decode(ThemeAppearance.self, forKey: .appearance)
        let raw = try container.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        // Unknown keys from newer versions are ignored instead of failing the whole theme.
        colors = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            ThemeSlot(rawValue: key).flatMap { slot in RGBAColor(hex: value).map { _ in (slot, value) } }
        })
        source = try container.decodeIfPresent(String.self, forKey: .source)
        isBuiltIn = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(author, forKey: .author)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) }), forKey: .colors)
        try container.encodeIfPresent(source, forKey: .source)
    }

    public func color(_ slot: ThemeSlot) -> RGBAColor? {
        colors[slot].flatMap(RGBAColor.init(hex:))
    }
}

/// A parsed color, independent of AppKit so themes can be tested in the core module.
public struct RGBAColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Accepts `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 || text.count == 4 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 8 {
            red = Double((value >> 24) & 0xff) / 255
            green = Double((value >> 16) & 0xff) / 255
            blue = Double((value >> 8) & 0xff) / 255
            alpha = Double(value & 0xff) / 255
        } else {
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
            alpha = 1
        }
    }

    public var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    /// This color painted over `background` at its own alpha, giving an opaque color.
    public func composited(over background: RGBAColor) -> RGBAColor {
        RGBAColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }

    public func mixed(with other: RGBAColor, amount: Double) -> RGBAColor {
        RGBAColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            alpha: alpha + (other.alpha - alpha) * amount
        )
    }

    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}
