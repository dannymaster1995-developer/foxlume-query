import Foundation

public enum ThemeImportError: Error, LocalizedError {
    case unreadable(String)
    case notATheme(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "The theme file could not be read: \(detail)"
        case .notATheme(let detail): return "This file is not a VS Code color theme: \(detail)"
        }
    }
}

/// Converts VS Code color themes (`*-color-theme.json`, JSON with comments) into Foxlume Query themes.
///
/// Editor colors come from the `colors` map (`editor.background`, …). Syntax colors come from
/// `tokenColors`, resolved with TextMate scope matching: a rule selector matches a scope when it is
/// equal to it or a dot-separated prefix of it, and the longest matching selector wins.
public enum VSCodeThemeImporter {
    /// Scopes tried, in order, for each syntax role.
    static let scopes: [(ThemeSlot, [String])] = [
        (.syntaxKeyword, ["keyword.other.sql", "keyword.control", "keyword", "storage.type", "storage"]),
        (.syntaxString, ["string.quoted.single", "string.quoted", "string"]),
        (.syntaxNumber, ["constant.numeric", "constant"]),
        (.syntaxComment, ["comment.line", "comment.block", "comment"]),
        (.syntaxIdentifier, ["variable.other", "variable", "entity.name.tag", "support.type.property-name"]),
        (.syntaxFunction, ["entity.name.function", "support.function", "meta.function-call"]),
    ]

    /// - Parameters:
    ///   - data: the theme JSON.
    ///   - fallbackName: used when the file has no `name`.
    ///   - uiTheme: `vs` / `vs-dark` / `hc-black` from the extension manifest, when known.
    ///   - parent: resolves an `include` path relative to the theme file.
    public static func importTheme(from data: Data, fallbackName: String, uiTheme: String? = nil, parent: ((String) -> Data?)? = nil) throws -> ThemeDefinition {
        let root = try parse(data)
        var colors: [String: String] = [:]
        var rules: [(selector: String, foreground: String)] = []
        var name = (root["name"] as? String) ?? fallbackName
        var type = (root["type"] as? String) ?? uiTheme

        // Themes may extend another file; the child's values override the parent's.
        if let include = root["include"] as? String, let parentData = parent?(include), let base = try? parse(parentData) {
            collect(from: base, colors: &colors, rules: &rules)
            if type == nil { type = base["type"] as? String }
        }
        collect(from: root, colors: &colors, rules: &rules)
        guard !colors.isEmpty || !rules.isEmpty else {
            throw ThemeImportError.notATheme("it has neither \"colors\" nor \"tokenColors\"")
        }
        if name.isEmpty { name = fallbackName }

        let background = colors["editor.background"].flatMap(RGBAColor.init(hex:))
        let appearance: ThemeAppearance
        switch type?.lowercased() {
        case "light", "vs", "hc-light": appearance = .light
        case "dark", "vs-dark", "hc-black": appearance = .dark
        default: appearance = (background?.luminance ?? 0) > 0.5 ? .light : .dark
        }
        let base = background ?? (appearance == .dark ? RGBAColor(red: 0.12, green: 0.12, blue: 0.12) : RGBAColor(red: 1, green: 1, blue: 1))
        let foregroundColor = colors["editor.foreground"].flatMap(RGBAColor.init(hex:)) ?? rules.first { $0.selector.isEmpty }.flatMap { RGBAColor(hex: $0.foreground) }
            ?? (appearance == .dark ? RGBAColor(red: 0.85, green: 0.85, blue: 0.85) : RGBAColor(red: 0.15, green: 0.15, blue: 0.15))

        /// VS Code colors may be translucent overlays; flatten them onto the editor background.
        func opaque(_ key: String) -> String? {
            guard let color = colors[key].flatMap(RGBAColor.init(hex:)) else { return nil }
            return color.composited(over: base).hex
        }

        var result: [ThemeSlot: String] = [:]
        result[.editorBackground] = base.hex
        result[.editorForeground] = foregroundColor.hex
        result[.editorCurrentLine] = opaque("editor.lineHighlightBackground") ?? base.mixed(with: foregroundColor, amount: 0.06).hex
        result[.editorSelection] = opaque("editor.selectionBackground") ?? base.mixed(with: foregroundColor, amount: 0.2).hex
        result[.editorLineNumber] = opaque("editorLineNumber.foreground") ?? base.mixed(with: foregroundColor, amount: 0.45).hex
        result[.editorCursor] = opaque("editorCursor.foreground") ?? foregroundColor.hex
        result[.gridBackground] = base.hex
        result[.gridText] = foregroundColor.hex
        result[.windowBackdrop] = opaque("sideBar.background") ?? opaque("editorGroupHeader.tabsBackground") ?? base.mixed(with: RGBAColor(red: 0, green: 0, blue: 0), amount: 0.12).hex

        for (slot, candidates) in scopes {
            if let color = candidates.lazy.compactMap({ resolve($0, rules: rules) }).first,
               let parsed = RGBAColor(hex: color) {
                result[slot] = parsed.composited(over: base).hex
            }
        }
        result[.gridNull] = result[.syntaxComment] ?? base.mixed(with: foregroundColor, amount: 0.5).hex
        result[.gridRowNumber] = result[.editorLineNumber]
        result.merge(BuiltInThemes.derivedGridColors(background: base.hex, foreground: foregroundColor.hex, appearance: appearance)) { current, _ in current }
        if let inserted = opaque("diffEditor.insertedTextBackground") { result[.gridInserted] = inserted }
        if let removed = opaque("diffEditor.removedTextBackground") { result[.gridDeleted] = removed }

        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        return ThemeDefinition(
            id: "vscode.\(slug)",
            name: name,
            author: (root["author"] as? String) ?? "",
            appearance: appearance,
            colors: result,
            source: "VS Code theme"
        )
    }

    private static func collect(from root: [String: Any], colors: inout [String: String], rules: inout [(selector: String, foreground: String)]) {
        if let map = root["colors"] as? [String: Any] {
            for (key, value) in map {
                if let hex = value as? String, RGBAColor(hex: hex) != nil { colors[key] = hex }
            }
        }
        guard let tokens = root["tokenColors"] as? [[String: Any]] else { return }
        for token in tokens {
            guard let settings = token["settings"] as? [String: Any], let foreground = settings["foreground"] as? String, RGBAColor(hex: foreground) != nil else { continue }
            let selectors: [String]
            if let scope = token["scope"] as? String {
                selectors = scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let list = token["scope"] as? [String] {
                selectors = list
            } else {
                selectors = [""]
            }
            for selector in selectors {
                // Descendant selectors ("meta.x keyword") count by their last part only.
                let last = selector.split(separator: " ").last.map(String.init) ?? selector
                rules.append((last, foreground))
            }
        }
    }

    /// The color of the most specific rule whose selector equals `scope` or is a dot-prefix of it.
    /// Later rules win ties, as in VS Code.
    static func resolve(_ scope: String, rules: [(selector: String, foreground: String)]) -> String? {
        var best: (length: Int, color: String)?
        for rule in rules where !rule.selector.isEmpty {
            let matches = scope == rule.selector || scope.hasPrefix(rule.selector + ".")
            guard matches else { continue }
            if best == nil || rule.selector.count >= best!.length {
                best = (rule.selector.count, rule.foreground)
            }
        }
        return best?.color
    }

    /// JSON with comments and trailing commas, as VS Code allows.
    static func parse(_ data: Data) throws -> [String: Any] {
        let cleaned = stripJSONC(String(decoding: data, as: UTF8.self))
        guard let object = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else {
            throw ThemeImportError.unreadable("invalid JSON")
        }
        return object
    }

    static func stripJSONC(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        while index < text.endIndex {
            let c = text[index]
            let next = text.index(after: index) < text.endIndex ? text[text.index(after: index)] : "\0"
            if inString {
                output.append(c)
                if c == "\\", next != "\0" {
                    output.append(next)
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                if c == "\"" { inString = false }
                index = text.index(after: index)
            } else if c == "\"" {
                inString = true
                output.append(c)
                index = text.index(after: index)
            } else if c == "/", next == "/" {
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
            } else if c == "/", next == "*" {
                index = text.index(index, offsetBy: 2)
                while index < text.endIndex {
                    if text[index] == "*", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "/" {
                        index = text.index(index, offsetBy: 2)
                        break
                    }
                    index = text.index(after: index)
                }
            } else {
                output.append(c)
                index = text.index(after: index)
            }
        }
        // Trailing commas before } or ].
        return output.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
    }

    /// Reads `extension/package.json` of an unpacked `.vsix` and returns its color themes.
    public static func themes(inExtensionAt directory: URL) throws -> [ThemeDefinition] {
        let root = directory.appendingPathComponent("extension")
        let base = FileManager.default.fileExists(atPath: root.appendingPathComponent("package.json").path) ? root : directory
        guard let manifestData = try? Data(contentsOf: base.appendingPathComponent("package.json")),
              let manifest = try? parse(manifestData),
              let contributes = manifest["contributes"] as? [String: Any],
              let entries = contributes["themes"] as? [[String: Any]], !entries.isEmpty
        else {
            throw ThemeImportError.notATheme("the extension contributes no color themes")
        }
        var result: [ThemeDefinition] = []
        for entry in entries {
            guard let path = entry["path"] as? String else { continue }
            let url = base.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let label = (entry["label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            var theme = try importTheme(from: data, fallbackName: label, uiTheme: entry["uiTheme"] as? String) { include in
                try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(include))
            }
            if let label = entry["label"] as? String { theme.name = label }
            theme.source = "VS Code extension: \((manifest["displayName"] as? String) ?? (manifest["name"] as? String) ?? "")"
            result.append(theme)
        }
        return result
    }
}
