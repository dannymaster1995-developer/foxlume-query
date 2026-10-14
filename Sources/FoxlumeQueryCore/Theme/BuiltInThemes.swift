import Foundation

/// Themes shipped with the app. Palettes follow each theme's published colors
/// (Dracula, One Dark, Nord, Solarized, GitHub Primer, Monokai, Catppuccin); credits are in THIRD_PARTY_NOTICES.md.
public enum BuiltInThemes {
    public static let defaultLightID = "foxlume.default-light"
    public static let defaultDarkID = "foxlume.default-dark"

    /// The system look: no colors set, so every slot uses the macOS defaults.
    public static let defaultLight = ThemeDefinition(id: defaultLightID, name: "Default Light", author: "Foxlume Query", appearance: .light, colors: [:], isBuiltIn: true)
    public static let defaultDark = ThemeDefinition(id: defaultDarkID, name: "Default Dark", author: "Foxlume Query", appearance: .dark, colors: [:], isBuiltIn: true)

    public static let all: [ThemeDefinition] = [
        defaultLight,
        defaultDark,
        palette(id: "dracula", name: "Dracula", author: "Zeno Rocha", appearance: .dark,
                background: "#282A36", foreground: "#F8F8F2", currentLine: "#44475A", selection: "#44475A", lineNumber: "#6272A4",
                keyword: "#FF79C6", string: "#F1FA8C", number: "#BD93F9", comment: "#6272A4", identifier: "#8BE9FD", function: "#50FA7B",
                cursor: "#F8F8F2", backdrop: "#21222C"),
        palette(id: "one-dark", name: "One Dark", author: "Atom", appearance: .dark,
                background: "#282C34", foreground: "#ABB2BF", currentLine: "#2C313C", selection: "#3E4451", lineNumber: "#4B5263",
                keyword: "#C678DD", string: "#98C379", number: "#D19A66", comment: "#5C6370", identifier: "#E06C75", function: "#61AFEF",
                cursor: "#528BFF", backdrop: "#21252B"),
        palette(id: "one-light", name: "One Light", author: "Atom", appearance: .light,
                background: "#FAFAFA", foreground: "#383A42", currentLine: "#F2F2F2", selection: "#E5E5E6", lineNumber: "#9D9D9F",
                keyword: "#A626A4", string: "#50A14F", number: "#986801", comment: "#A0A1A7", identifier: "#E45649", function: "#4078F2",
                cursor: "#526FFF", backdrop: "#EAEAEB"),
        palette(id: "nord", name: "Nord", author: "Arctic Ice Studio", appearance: .dark,
                background: "#2E3440", foreground: "#D8DEE9", currentLine: "#3B4252", selection: "#434C5E", lineNumber: "#4C566A",
                keyword: "#81A1C1", string: "#A3BE8C", number: "#B48EAD", comment: "#616E88", identifier: "#8FBCBB", function: "#88C0D0",
                cursor: "#D8DEE9", backdrop: "#242933"),
        palette(id: "solarized-dark", name: "Solarized Dark", author: "Ethan Schoonover", appearance: .dark,
                background: "#002B36", foreground: "#839496", currentLine: "#073642", selection: "#274642", lineNumber: "#586E75",
                keyword: "#859900", string: "#2AA198", number: "#D33682", comment: "#586E75", identifier: "#268BD2", function: "#B58900",
                cursor: "#D30102", backdrop: "#00212B"),
        palette(id: "solarized-light", name: "Solarized Light", author: "Ethan Schoonover", appearance: .light,
                background: "#FDF6E3", foreground: "#657B83", currentLine: "#EEE8D5", selection: "#EEE8D5", lineNumber: "#93A1A1",
                keyword: "#859900", string: "#2AA198", number: "#D33682", comment: "#93A1A1", identifier: "#268BD2", function: "#B58900",
                cursor: "#657B83", backdrop: "#EEE8D5"),
        palette(id: "github-light", name: "GitHub Light", author: "GitHub", appearance: .light,
                background: "#FFFFFF", foreground: "#24292F", currentLine: "#F6F8FA", selection: "#DDF4FF", lineNumber: "#8C959F",
                keyword: "#CF222E", string: "#0A3069", number: "#0550AE", comment: "#6E7781", identifier: "#953800", function: "#8250DF",
                cursor: "#0969DA", backdrop: "#F6F8FA"),
        palette(id: "github-dark", name: "GitHub Dark", author: "GitHub", appearance: .dark,
                background: "#0D1117", foreground: "#C9D1D9", currentLine: "#161B22", selection: "#264F78", lineNumber: "#6E7681",
                keyword: "#FF7B72", string: "#A5D6FF", number: "#79C0FF", comment: "#8B949E", identifier: "#FFA657", function: "#D2A8FF",
                cursor: "#58A6FF", backdrop: "#010409"),
        palette(id: "monokai", name: "Monokai", author: "Wimer Hazenberg", appearance: .dark,
                background: "#272822", foreground: "#F8F8F2", currentLine: "#3E3D32", selection: "#49483E", lineNumber: "#90908A",
                keyword: "#F92672", string: "#E6DB74", number: "#AE81FF", comment: "#75715E", identifier: "#66D9EF", function: "#A6E22E",
                cursor: "#F8F8F0", backdrop: "#1E1F1C"),
        palette(id: "catppuccin-mocha", name: "Catppuccin Mocha", author: "Catppuccin", appearance: .dark,
                background: "#1E1E2E", foreground: "#CDD6F4", currentLine: "#313244", selection: "#45475A", lineNumber: "#6C7086",
                keyword: "#CBA6F7", string: "#A6E3A1", number: "#FAB387", comment: "#6C7086", identifier: "#F38BA8", function: "#89B4FA",
                cursor: "#F5E0DC", backdrop: "#181825"),
        palette(id: "catppuccin-latte", name: "Catppuccin Latte", author: "Catppuccin", appearance: .light,
                background: "#EFF1F5", foreground: "#4C4F69", currentLine: "#E6E9EF", selection: "#CCD0DA", lineNumber: "#9CA0B0",
                keyword: "#8839EF", string: "#40A02B", number: "#FE640B", comment: "#9CA0B0", identifier: "#D20F39", function: "#1E66F5",
                cursor: "#DC8A78", backdrop: "#E6E9EF"),
    ]

    /// Builds a full theme from an editor palette; grid colors are derived so rows stay readable.
    public static func palette(
        id: String, name: String, author: String, appearance: ThemeAppearance,
        background: String, foreground: String, currentLine: String, selection: String, lineNumber: String,
        keyword: String, string: String, number: String, comment: String, identifier: String, function: String,
        cursor: String, backdrop: String
    ) -> ThemeDefinition {
        var colors: [ThemeSlot: String] = [
            .editorBackground: background,
            .editorForeground: foreground,
            .editorCurrentLine: currentLine,
            .editorSelection: selection,
            .editorLineNumber: lineNumber,
            .editorCursor: cursor,
            .syntaxKeyword: keyword,
            .syntaxString: string,
            .syntaxNumber: number,
            .syntaxComment: comment,
            .syntaxIdentifier: identifier,
            .syntaxFunction: function,
            .gridBackground: background,
            .gridText: foreground,
            .gridNull: comment,
            .gridRowNumber: lineNumber,
            .windowBackdrop: backdrop,
        ]
        colors.merge(derivedGridColors(background: background, foreground: foreground, appearance: appearance)) { current, _ in current }
        return ThemeDefinition(id: "foxlume.\(id)", name: name, author: author, appearance: appearance, colors: colors, isBuiltIn: true)
    }

    /// Alternate rows and change highlights mixed from the background, so they fit any palette.
    public static func derivedGridColors(background: String, foreground: String, appearance: ThemeAppearance) -> [ThemeSlot: String] {
        guard let bg = RGBAColor(hex: background), let fg = RGBAColor(hex: foreground) else { return [:] }
        let strength = appearance == .dark ? 0.28 : 0.22
        return [
            .gridAlternateRow: bg.mixed(with: fg, amount: appearance == .dark ? 0.04 : 0.03).hex,
            .gridModified: bg.mixed(with: RGBAColor(red: 0.95, green: 0.78, blue: 0.2), amount: strength).hex,
            .gridInserted: bg.mixed(with: RGBAColor(red: 0.3, green: 0.75, blue: 0.4), amount: strength).hex,
            .gridDeleted: bg.mixed(with: RGBAColor(red: 0.9, green: 0.3, blue: 0.3), amount: strength).hex,
        ]
    }
}
