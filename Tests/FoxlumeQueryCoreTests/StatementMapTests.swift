import Foundation
import Testing
@testable import FoxlumeQueryCore

/// The statement at the caret (for the editor's band) and the next statement's start (for ⌃⌘↩).
@Suite struct StatementMapTests {
    private func offset(of needle: String, in text: String) -> Int {
        (text as NSString).range(of: needle).location
    }

    private func band(_ text: String, at caret: Int, _ language: QueryLanguage = .sql(.postgresql)) -> String? {
        StatementMap(text: text, language: language).bandRange(at: caret).map { (text as NSString).substring(with: $0) }
    }

    private func next(_ text: String, after caret: Int, _ language: QueryLanguage = .sql(.postgresql)) -> String? {
        StatementMap(text: text, language: language).nextStatementStart(after: NSRange(location: caret, length: 0))
            .map { String((text as NSString).substring(from: $0).prefix(12)) }
    }

    @Test func bandCoversTheStatementAndItsSemicolon() {
        let text = "SELECT 1;\nSELECT 2 ;\n\nSELECT 3"
        #expect(band(text, at: 0) == "SELECT 1;")
        #expect(band(text, at: 8) == "SELECT 1;", "just before the ;")
        #expect(band(text, at: 9) == "SELECT 1;", "just after the ;")
        #expect(band(text, at: offset(of: "2", in: text)) == "SELECT 2 ;")
        #expect(band(text, at: (text as NSString).length) == "SELECT 3")
    }

    @Test func noBandBetweenStatementsOrForASingleStatement() {
        let text = "SELECT 1;\n\n   \nSELECT 2;"
        #expect(band(text, at: 11) == nil, "on the blank line between the statements")
        #expect(band(text, at: 13) == nil)
        #expect(band("SELECT 1;\n", at: 3) == nil)
        #expect(band("SELECT 1; -- only one", at: 3) == nil, "a trailing comment is not a statement")
        #expect(band("", at: 0) == nil)
    }

    /// `SELECT 1; -- note` keeps its note on its own line: the next statement's band starts on the following line.
    @Test func aCommentTrailingTheStatementBeforeIsNotInTheBand() {
        let text = "SELECT 1; -- first\n-- about two\nSELECT 2;\nSELECT 3;"
        #expect(band(text, at: (text as NSString).range(of: "SELECT 2").location) == "-- about two\nSELECT 2;")
        #expect(band(text, at: (text as NSString).range(of: "first").location) == nil)
        #expect(next(text, after: 0) == "SELECT 2;\nSE")
        // Run Statement still runs the second statement from the trailing comment, as the splitter places it there.
        let map = StatementMap(text: text, language: .sql(.postgresql))
        #expect(map.runIndex(at: (text as NSString).range(of: "first").location) == 1)
    }

    @Test func semicolonsInStringsAndCommentsDoNotSplit() {
        let text = "SELECT 'a;b', \"c;d\" -- e;f\nFROM t /* g; h */;\nSELECT 2;"
        let first = band(text, at: offset(of: "FROM", in: text))
        #expect(first == "SELECT 'a;b', \"c;d\" -- e;f\nFROM t /* g; h */;")
        #expect(next(text, after: 3) == "SELECT 2;")
    }

    @Test func dollarQuotedBodiesStayWhole() {
        let body = "CREATE FUNCTION f() RETURNS int AS $body$\nBEGIN\n  PERFORM 1;\n  RETURN 2;\nEND;\n$body$ LANGUAGE plpgsql;"
        let text = "SELECT 0;\n" + body + "\nSELECT 3;"
        #expect(band(text, at: offset(of: "PERFORM", in: text)) == body)
        #expect(next(text, after: offset(of: "RETURN 2", in: text)) == "SELECT 3;")
        #expect(next(text, after: 2) == "CREATE FUNCT")
    }

    @Test func mysqlRoutinesWithoutDelimiterStayWhole() {
        let procedure = "CREATE PROCEDURE p()\nBEGIN\n  DECLARE n INT;\n  SET n = 1;\nEND"
        let text = "DROP PROCEDURE IF EXISTS p;\n" + procedure + ";\n# done\nCALL p();"
        let language = QueryLanguage.sql(.mysql)
        #expect(band(text, at: offset(of: "SET n", in: text), language) == procedure + ";")
        #expect(next(text, after: offset(of: "DECLARE", in: text), language) == "CALL p();", "the # comment is skipped")
    }

    @Test func nextStatementSkipsCommentsAndBlankLines() {
        let text = "SELECT 1;\n\n-- the second\n/* block\n   comment */\n  SELECT 2;\nSELECT 3;"
        #expect(next(text, after: 0) == "SELECT 2;\nSE")
        #expect(next(text, after: offset(of: "second", in: text)) == "SELECT 3;", "the comment belongs to the second statement")
        #expect(next(text, after: offset(of: "SELECT 3", in: text)) == nil, "the last statement has no next")
        #expect(next("SELECT 1", after: 0) == nil)
    }

    @Test func nextStatementMatchesWhatRunStatementRuns() {
        // Between two statements Run Statement runs the one before, so the next one is the statement after the gap.
        let text = "SELECT 1;\n\nSELECT 2;\n\nSELECT 3;"
        #expect(next(text, after: 10) == "SELECT 2;\n\nS")
        // Before the first statement Run Statement runs the first.
        #expect(next("\n\nSELECT 1;\nSELECT 2;", after: 0) == "SELECT 2;")
        let map = StatementMap(text: text, language: .sql(.postgresql))
        for caret in 0...(text as NSString).length {
            let ran = QueryLanguage.sql(.postgresql).statement(at: caret, in: text)?.range.location
            #expect(map.runIndex(at: caret).map { map.entries[$0].range.location } == ran, "caret \(caret)")
        }
    }

    @Test func aSelectedLineEndingAtTheNextStatementStillMovesToIt() {
        let text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let map = StatementMap(text: text, language: .sql(.postgresql))
        #expect(map.nextStatementStart(after: NSRange(location: 0, length: 10)) == 10)
        #expect(map.nextStatementStart(after: NSRange(location: 2, length: 12)) == 20, "a selection ending inside the second moves to the third")
    }

    @Test func executableMySQLCommentsAreCode() {
        let text = "SELECT 1;\n/*!40101 SET NAMES utf8 */;"
        #expect(next(text, after: 0, .sql(.mysql)) == "/*!40101 SET")
    }

    @Test func mongoAndRedisUseTheirRunRules() {
        let mongo = "db.a.find({ x: \"1;2\" })\n// next\ndb.b.find()"
        #expect(band(mongo, at: 3, .mongo) == "db.a.find({ x: \"1;2\" })")
        #expect(next(mongo, after: 3, .mongo) == "db.b.find()")
        let redis = "GET a\n# note\nSET b \"x;y\"; DEL c"
        #expect(band(redis, at: offset(of: "SET", in: redis), .redis) == "SET b \"x;y\";")
        #expect(next(redis, after: 1, .redis) == "SET b \"x;y\";")
        #expect(next(redis, after: offset(of: "SET", in: redis), .redis) == "DEL c")
    }

    @Test func utf16Offsets() {
        let text = "SELECT '😀';\nSELECT 'é';"
        let map = StatementMap(text: text, language: .sql(.postgresql))
        #expect(map.entries.map(\.range.location) == [0, 13])
        #expect(map.bandRange(at: 12) == NSRange(location: 0, length: 12))
    }

    @Test func editsShiftTheMapUntilTheNextSplit() {
        let text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let map = StatementMap(text: text, language: .sql(.postgresql))
        // Typing "0" at the end of "SELECT 2" grows the second statement and moves the third.
        let typed = map.shifted(byEditing: NSRange(location: 18, length: 1), changeInLength: 1)
        #expect(typed.entries.map(\.range) == [NSRange(location: 0, length: 9), NSRange(location: 10, length: 10), NSRange(location: 21, length: 9)])
        #expect(typed.bandRange(at: 19) == NSRange(location: 10, length: 10), "the caret after the typed character stays in the band")
        let resplit = StatementMap(text: "SELECT 1;\nSELECT 20;\nSELECT 3;", language: .sql(.postgresql))
        #expect(typed == resplit)

        // Deleting the first line moves everything after it back.
        let deleted = map.shifted(byEditing: NSRange(location: 0, length: 0), changeInLength: -10)
        #expect(deleted.entries.map(\.range.location) == [0, 0, 10])
        #expect(deleted.entries[0].range.length == 0)
        #expect(deleted.entries[1].range == NSRange(location: 0, length: 9))

        // Typing before a statement leaves it whole and moves it.
        let before = map.shifted(byEditing: NSRange(location: 10, length: 2), changeInLength: 2)
        #expect(before.entries[1].range == NSRange(location: 12, length: 9))
        #expect(before.entries[1].codeStart == 12)
    }
}

@Suite struct StatementBandColorTests {
    private func band(_ theme: ThemeDefinition) -> (band: RGBAColor, background: RGBAColor, text: RGBAColor) {
        let dark = theme.appearance == .dark
        let background = theme.color(.editorBackground) ?? (dark ? .black : .white)
        // The default themes set no colors; the app then passes the macOS text selection color.
        let selection = theme.color(.editorSelection) ?? RGBAColor(hex: dark ? "#3F638B" : "#B3D7FF")
        let color = StatementBandColor.color(
            background: background, selection: selection, currentLine: theme.color(.editorCurrentLine),
            foreground: theme.color(.editorForeground), dark: dark
        )
        return (color, background, theme.color(.editorForeground) ?? (dark ? .white : .black))
    }

    /// Every built-in theme gets a band that shows and keeps the text about as readable as on the background.
    @Test func builtInThemesGetAVisibleReadableBand() {
        for theme in BuiltInThemes.all {
            let (color, background, text) = band(theme)
            #expect(color.alpha == 1)
            #expect(StatementBandColor.distance(color, background) >= StatementBandColor.minimumDistance - 0.0001, "\(theme.name): band too faint")
            #expect(StatementBandColor.distance(color, background) <= 0.2, "\(theme.name): band too strong")
            #expect(text.contrastRatio(with: color) >= text.contrastRatio(with: background) * 0.75, "\(theme.name): text loses contrast")
        }
    }

    @Test func darkAndLightBandsMoveTowardTheSelection() {
        let light = StatementBandColor.color(background: .white, selection: RGBAColor(hex: "#B3D7FF"), currentLine: nil, foreground: .black, dark: false)
        #expect(light.blue > light.red, "a blue selection gives a blue tint")
        #expect(light.luminance < 1)
        let dark = StatementBandColor.color(background: RGBAColor(hex: "#1E1E1E")!, selection: RGBAColor(hex: "#264F78"), currentLine: nil, foreground: .white, dark: true)
        #expect(dark.luminance > RGBAColor(hex: "#1E1E1E")!.luminance)
    }

    /// The caret's line keeps standing out inside the band, the way it does outside it.
    @Test func currentLineInsideTheBand() {
        for theme in BuiltInThemes.all {
            guard let line = theme.color(.editorCurrentLine), let background = theme.color(.editorBackground) else { continue }
            let (color, _, _) = band(theme)
            let inBand = StatementBandColor.currentLine(band: color, background: background, currentLine: line, dark: theme.appearance == .dark)
            #expect(abs(StatementBandColor.distance(inBand, color) - StatementBandColor.distance(line, background)) < 0.01, "\(theme.name)")
        }
        let light = StatementBandColor.currentLine(band: RGBAColor(hex: "#E8F3FF")!, background: .white, currentLine: RGBAColor(hex: "#ECF5FF")!, dark: false)
        #expect(light.red < 0.91 && light.blue == 1, "darker than the band in a light theme, never past white")
    }

    /// Imported themes can set a selection equal to the background or a translucent one.
    @Test func faintOrTranslucentSelectionsStillShow() {
        let background = RGBAColor(hex: "#282A36")!
        let same = StatementBandColor.color(background: background, selection: background, currentLine: nil, foreground: RGBAColor(hex: "#F8F8F2"), dark: true)
        #expect(StatementBandColor.distance(same, background) >= StatementBandColor.minimumDistance - 0.0001)
        #expect(same.luminance > background.luminance, "leans toward the light text")

        let translucent = StatementBandColor.color(background: .white, selection: RGBAColor(hex: "#ADD6FF26"), currentLine: nil, foreground: RGBAColor(hex: "#000000"), dark: false)
        #expect(translucent.alpha == 1)
        #expect(StatementBandColor.distance(translucent, .white) >= StatementBandColor.minimumDistance - 0.0001)

        let noColors = StatementBandColor.color(background: .white, selection: nil, currentLine: nil, foreground: nil, dark: false)
        #expect(noColors.luminance < 1)
    }
}

@Suite struct EditorSettingsTests {
    /// Wrapping and the band are on by default, also for settings saved before they existed, and are remembered.
    @Test func wordWrapAndStatementBandDefaultOnAndRoundTrip() throws {
        #expect(AppSettings().editorWordWrap && AppSettings().highlightCurrentStatement)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"editorFontSize": 14}"#.utf8))
        #expect(old.editorWordWrap && old.highlightCurrentStatement)
        var settings = AppSettings()
        settings.editorWordWrap = false
        settings.highlightCurrentStatement = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.editorWordWrap && !decoded.highlightCurrentStatement)
    }
}
