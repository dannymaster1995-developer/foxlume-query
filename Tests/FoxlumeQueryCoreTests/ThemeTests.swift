import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct ThemeTests {
    @Test func themeIDsFromBeforeTheRenameAreMigrated() throws {
        let saved = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"lightThemeID": "easyquery.one-light", "darkThemeID": "easyquery.default-dark"}"#.utf8))
        #expect(saved.lightThemeID == "foxlume.one-light")
        #expect(saved.darkThemeID == BuiltInThemes.defaultDarkID)
        let imported = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"darkThemeID": "imported.dracula-pro"}"#.utf8))
        #expect(imported.darkThemeID == "imported.dracula-pro")
    }

    @Test func appearanceModeDefaultsToSystemAndRoundTrips() throws {
        #expect(AppSettings().appearance == .system)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"darkThemeID": "dracula"}"#.utf8))
        #expect(old.appearance == .system)
        var settings = AppSettings()
        settings.appearance = .dark
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.appearance == .dark)
        #expect(AppearanceMode.allCases.map(\.title) == ["System", "Light", "Dark"])
    }

    @Test func parsesHexColors() {
        #expect(RGBAColor(hex: "#ff8000")?.hex == "#FF8000")
        #expect(RGBAColor(hex: "#F80")?.hex == "#FF8800")
        #expect(RGBAColor(hex: "#00000080")?.alpha ?? 0 > 0.49)
        #expect(RGBAColor(hex: "red") == nil)
        let overlay = RGBAColor(hex: "#FFFFFF80")!.composited(over: RGBAColor(hex: "#000000")!)
        #expect(overlay.hex == "#808080")
    }

    @Test func builtInThemesAreComplete() {
        for theme in BuiltInThemes.all where !theme.colors.isEmpty {
            for slot in ThemeSlot.allCases {
                #expect(theme.color(slot) != nil, "\(theme.name) misses \(slot)")
            }
        }
        #expect(Set(BuiltInThemes.all.map(\.id)).count == BuiltInThemes.all.count)
    }

    @Test func importsVSCodeThemeWithCommentsAndScopes() throws {
        let json = """
        // Dracula-like test theme
        {
          "name": "Test Night",
          "type": "dark",
          "colors": {
            "editor.background": "#282A36",
            "editor.foreground": "#F8F8F2",
            "editor.lineHighlightBackground": "#44475A75", // translucent
            "editorLineNumber.foreground": "#6272A4",
          },
          "tokenColors": [
            { "scope": "comment", "settings": { "foreground": "#6272A4", "fontStyle": "italic" } },
            { "scope": ["string", "string.quoted"], "settings": { "foreground": "#F1FA8C" } },
            { "scope": "keyword", "settings": { "foreground": "#FF79C6" } },
            { "scope": "keyword.control", "settings": { "foreground": "#FF0000" } },
            { "scope": "constant.numeric", "settings": { "foreground": "#BD93F9" } },
            { "scope": "meta.function-call entity.name.function, support.function", "settings": { "foreground": "#50FA7B" } }
          ]
        }
        """
        let theme = try VSCodeThemeImporter.importTheme(from: Data(json.utf8), fallbackName: "x")
        #expect(theme.name == "Test Night")
        #expect(theme.appearance == .dark)
        #expect(theme.colors[.editorBackground] == "#282A36")
        #expect(theme.colors[.syntaxComment] == "#6272A4")
        #expect(theme.colors[.syntaxString] == "#F1FA8C")
        // SQL keywords are `keyword.other.*` scopes, so the general keyword rule applies, not keyword.control.
        #expect(theme.colors[.syntaxKeyword] == "#FF79C6")
        #expect(theme.colors[.syntaxNumber] == "#BD93F9")
        #expect(theme.colors[.syntaxFunction] == "#50FA7B")
        // Translucent highlight is flattened onto the background.
        #expect(theme.colors[.editorCurrentLine]?.count == 7)
        #expect(theme.colors[.gridModified] != nil)
    }

    @Test func detectsLightThemesWithoutType() throws {
        let json = ##"{ "colors": { "editor.background": "#FFFFFF", "editor.foreground": "#333333" }, "tokenColors": [] }"##
        let theme = try VSCodeThemeImporter.importTheme(from: Data(json.utf8), fallbackName: "Paper")
        #expect(theme.appearance == .light)
        #expect(theme.name == "Paper")
    }

    @Test func rejectsNonThemes() {
        #expect(throws: ThemeImportError.self) {
            _ = try VSCodeThemeImporter.importTheme(from: Data(#"{ "foo": 1 }"#.utf8), fallbackName: "x")
        }
    }

    @Test func storeSavesUniqueNamesAndRoundTrips() throws {
        let folder = TestFiles.url("themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ThemeStore(directory: folder)
        let theme = ThemeDefinition(id: "my.theme", name: "Dracula", appearance: .dark, colors: [.editorBackground: "#101010"])
        let saved = try store.save(theme)
        #expect(saved.name == "Dracula 2")
        let again = ThemeStore(directory: folder)
        #expect(again.theme(id: saved.id)?.colors[.editorBackground] == "#101010")
        again.delete(id: saved.id)
        #expect(again.theme(id: saved.id) == nil)
    }
}
