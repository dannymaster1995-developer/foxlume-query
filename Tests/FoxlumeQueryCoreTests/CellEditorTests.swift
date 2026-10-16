import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct CellEditorKindTests {
    private func kind(_ type: String, _ engine: DatabaseKind, enumValues: [String]? = nil) -> CellEditorKind {
        CellEditorKind.classify(ColumnInfo(name: "c", dataType: type, enumValues: enumValues), kind: engine)
    }

    @Test func booleansPerEngine() {
        #expect(kind("boolean", .postgresql) == .boolean(.letters))
        #expect(kind("tinyint(1)", .mysql) == .boolean(.numeric))
        #expect(kind("tinyint(1) unsigned", .mariadb) == .boolean(.numeric))
        #expect(kind("tinyint(4)", .mysql) == .text, "only display width 1 is a boolean")
        #expect(kind("tinyint", .mysql) == .text)
        #expect(kind("BOOLEAN", .sqlite) == .boolean(.numeric))
        #expect(kind("BOOLEAN", .duckdb) == .boolean(.words))
        #expect(kind("boolean[]", .postgresql) == .text, "arrays keep the text editor")
        #expect(kind("boolean", .mongodb) == .text)
        #expect(kind("bool", .redis) == .text)
    }

    @Test func datesAndTimes() {
        #expect(kind("date", .postgresql) == .temporal(.date))
        #expect(kind("time without time zone", .postgresql) == .temporal(.time(withTimeZone: false)))
        #expect(kind("time(3) with time zone", .postgresql) == .temporal(.time(withTimeZone: true)))
        #expect(kind("timestamp without time zone", .postgresql) == .temporal(.timestamp(withTimeZone: false)))
        #expect(kind("timestamp(6) with time zone", .postgresql) == .temporal(.timestamp(withTimeZone: true)))
        #expect(kind("datetime(6)", .mysql) == .temporal(.timestamp(withTimeZone: false)))
        #expect(kind("timestamp", .mariadb) == .temporal(.timestamp(withTimeZone: false)))
        #expect(kind("time(3)", .mysql) == .temporal(.time(withTimeZone: false)))
        #expect(kind("DATETIME", .sqlite) == .temporal(.timestamp(withTimeZone: false)))
        #expect(kind("TIMESTAMP WITH TIME ZONE", .duckdb) == .temporal(.timestamp(withTimeZone: true)))
        #expect(kind("TIMESTAMPTZ", .duckdb) == .temporal(.timestamp(withTimeZone: true)))
        #expect(kind("TIME", .duckdb) == .temporal(.time(withTimeZone: false)))
        for other in ["interval", "year", "daterange", "tstzrange", "date[]", "text"] {
            #expect(kind(other, .postgresql) == .text, "\(other)")
        }
        #expect(kind("year", .mysql) == .text)
    }

    @Test func enums() {
        #expect(kind("mood", .postgresql, enumValues: ["sad", "ok", "happy"]) == .choice(["sad", "ok", "happy"]))
        #expect(kind("mood", .postgresql) == .text)
        #expect(kind("enum('small','medium','large')", .mysql) == .choice(["small", "medium", "large"]))
        #expect(kind("ENUM('a', 'b')", .duckdb) == .choice(["a", "b"]))
        #expect(kind("set('a','b')", .mysql) == .text, "SET columns stay text")
    }

    @Test func enumLabelParsing() {
        #expect(EnumLabels.parse("enum('it''s','a,b','')", backslashEscapes: true) == ["it's", "a,b", ""])
        #expect(EnumLabels.parse(#"enum('back\\slash','q\'uote')"#, backslashEscapes: true) == [#"back\slash"#, "q'uote"])
        #expect(EnumLabels.parse(#"ENUM('a\b')"#, backslashEscapes: false) == [#"a\b"#])
        #expect(EnumLabels.parse("enum()", backslashEscapes: true) == [])
        #expect(EnumLabels.parse("enum('open", backslashEscapes: true) == nil)
        #expect(EnumLabels.parse("enum('a' 'b')", backslashEscapes: true) == nil)
        #expect(EnumLabels.parse("varchar(3)", backslashEscapes: true) == nil)
    }

    @Test func booleanSpellings() {
        #expect(BooleanStyle.letters.text(true) == "t")
        #expect(BooleanStyle.numeric.text(false) == "0")
        #expect(BooleanStyle.words.text(true) == "true")
        for yes in ["t", "TRUE", "1", "yes", " on "] { #expect(BooleanStyle.parse(yes) == true, "\(yes)") }
        for no in ["f", "False", "0", "no", "off"] { #expect(BooleanStyle.parse(no) == false, "\(no)") }
        #expect(BooleanStyle.parse("2") == nil)
        #expect(BooleanStyle.parse("") == nil)
    }

    @Test func referencePickerOnlyForSingleColumnKeys() {
        let structure = TableStructure(table: TableRef(name: "lines"), columns: [], foreignKeys: [
            ForeignKeyInfo(name: "fk_order", columns: ["order_id"], referencedTable: TableRef(name: "orders"), referencedColumns: ["id"]),
            ForeignKeyInfo(name: "fk_pair", columns: ["a", "b"], referencedTable: TableRef(name: "pairs"), referencedColumns: ["x", "y"]),
        ])
        #expect(ReferencePicker.foreignKey(forColumn: "order_id", in: structure)?.name == "fk_order")
        #expect(ReferencePicker.foreignKey(forColumn: "a", in: structure) == nil, "composite keys keep the text editor")
        #expect(ReferencePicker.foreignKey(forColumn: "qty", in: structure) == nil)
    }
}

@Suite struct TemporalTextTests {
    @Test func parsesAndRewritesExactly() throws {
        let samples: [(String, TemporalKind)] = [
            ("2024-03-05", .date),
            ("2024-03-05 14:07:09", .timestamp(withTimeZone: false)),
            ("2024-03-05 14:07:09.123456", .timestamp(withTimeZone: false)),
            ("2024-03-05 14:07:09.5+05:30", .timestamp(withTimeZone: true)),
            ("2024-03-05T14:07:09Z", .timestamp(withTimeZone: true)),
            ("2024-03-05 14:07:09+07", .timestamp(withTimeZone: true)),
            ("14:07:09", .time(withTimeZone: false)),
            ("14:07:09.25-03", .time(withTimeZone: true)),
            ("0044-03-15 BC", .date),
        ]
        for (text, kind) in samples {
            let value = try #require(TemporalText.parse(text, kind: kind), "\(text)")
            #expect(value.text == text)
        }
    }

    @Test func rejectsWhatThePickerCannotShow() {
        #expect(TemporalText.parse("infinity", kind: .timestamp(withTimeZone: true)) == nil)
        #expect(TemporalText.parse("838:59:59", kind: .time(withTimeZone: false)) == nil)
        #expect(TemporalText.parse("2024-13-01", kind: .date) == nil)
        #expect(TemporalText.parse("2024-01-01 10:00", kind: .date) == nil)
        #expect(TemporalText.parse("yesterday", kind: .date) == nil)
    }

    @Test func changingTheDateKeepsFractionAndZone() throws {
        let value = try #require(TemporalText.parse("2024-03-05 14:07:09.123456+05:30", kind: .timestamp(withTimeZone: true)))
        let moved = value.replacing(day: TemporalText.Day(year: 2025, month: 12, day: 31), clock: value.clock)
        #expect(moved.text == "2025-12-31 14:07:09.123456+05:30")
        let retimed = value.replacing(day: value.day, clock: TemporalText.Clock(hour: 8, minute: 0, second: 0))
        #expect(retimed.text == "2024-03-05 08:00:00+05:30", "a new clock time drops the fraction the picker cannot show")
    }

    @Test func bareDateInATimestampGetsMidnight() throws {
        let value = try #require(TemporalText.parse("2024-03-05", kind: .timestamp(withTimeZone: false)))
        #expect(value.clock == TemporalText.Clock(hour: 0, minute: 0, second: 0))
        #expect(value.replacing(day: TemporalText.Day(year: 2024, month: 3, day: 6), clock: nil).text == "2024-03-06 00:00:00")
    }

    @Test func currentValuePerKind() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 7 * 3600))
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        #expect(TemporalText.current(.date, date: date, timeZone: zone).text == "2023-11-15")
        #expect(TemporalText.current(.time(withTimeZone: false), date: date, timeZone: zone).text == "05:13:20")
        #expect(TemporalText.current(.timestamp(withTimeZone: false), date: date, timeZone: zone).text == "2023-11-15 05:13:20")
        #expect(TemporalText.current(.timestamp(withTimeZone: true), date: date, timeZone: zone).text == "2023-11-15 05:13:20+07:00")
        let india = try #require(TimeZone(secondsFromGMT: -(3 * 3600 + 1800)))
        #expect(TemporalText.current(.time(withTimeZone: true), date: date, timeZone: india).text == "18:43:20-03:30")
    }

    @Test func pickerDateRoundTrip() throws {
        let value = try #require(TemporalText.parse("1999-12-31 23:59:58", kind: .timestamp(withTimeZone: false)))
        let fields = TemporalText.fields(ofPickerDate: try #require(value.pickerDate))
        #expect(fields.day == TemporalText.Day(year: 1999, month: 12, day: 31))
        #expect(fields.clock == TemporalText.Clock(hour: 23, minute: 59, second: 58))
    }
}

@Suite struct ReferenceCandidateTests {
    @Test func sqlPerDialect() {
        let request = ReferenceCandidateRequest(table: TableRef(schema: "public", name: "users"), keyColumn: "id", labelColumn: "name", search: "", limit: 100)
        #expect(ReferenceCandidates.sql(request, dialect: .postgresql) == #"SELECT "id", "name" FROM "public"."users" ORDER BY "id" ASC LIMIT 100"#)
        var searched = request
        searched.search = "ann_%"
        searched.table = TableRef(name: "users")
        #expect(ReferenceCandidates.sql(searched, dialect: .mysql) == #"SELECT `id`, `name` FROM `users` WHERE (LOWER(CAST(`id` AS CHAR)) LIKE LOWER('%ann\\_\\%%') ESCAPE '\\' OR LOWER(CAST(`name` AS CHAR)) LIKE LOWER('%ann\\_\\%%') ESCAPE '\\') ORDER BY `id` ASC LIMIT 100"#)
        let unlabeled = ReferenceCandidateRequest(table: TableRef(name: "codes"), keyColumn: "code", labelColumn: nil, search: "o'k", limit: 5)
        #expect(ReferenceCandidates.sql(unlabeled, dialect: .sqlite) == #"SELECT "code" FROM "codes" WHERE (LOWER(CAST("code" AS TEXT)) LIKE LOWER('%o''k%') ESCAPE '\') ORDER BY "code" ASC LIMIT 5"#)
    }

    @Test func labelColumnIsTheFirstTextColumn() {
        let users = TableStructure(table: TableRef(name: "users"), columns: [
            ColumnInfo(name: "id", dataType: "integer"),
            ColumnInfo(name: "tags", dataType: "text[]"),
            ColumnInfo(name: "created", dataType: "timestamp"),
            ColumnInfo(name: "email", dataType: "character varying(200)"),
            ColumnInfo(name: "name", dataType: "text"),
        ])
        #expect(ReferenceCandidates.labelColumn(in: users, key: "id") == "email")
        let codes = TableStructure(table: TableRef(name: "codes"), columns: [ColumnInfo(name: "code", dataType: "varchar(3)"), ColumnInfo(name: "n", dataType: "int")])
        #expect(ReferenceCandidates.labelColumn(in: codes, key: "code") == nil, "the key itself is not its label")
    }

    @Test func candidatesSkipNullKeys() {
        var result = StatementResult()
        result.columns = [ResultColumn(name: "id", typeName: "int4", isNumeric: true), ResultColumn(name: "name", typeName: "text", isNumeric: false)]
        result.rows = [[.text("1"), .text("Ann")], [.null, .text("ghost")], [.text("2"), .null]]
        #expect(ReferenceCandidates.candidates(from: result, hasLabel: true) == [ReferenceCandidate(key: .text("1"), label: "Ann"), ReferenceCandidate(key: .text("2"), label: nil)])
    }
}
