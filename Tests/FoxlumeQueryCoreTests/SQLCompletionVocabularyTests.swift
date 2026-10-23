import Foundation
import Testing
@testable import FoxlumeQueryCore

private typealias Vocabulary = SQLCompletionVocabulary

private let families: [SQLDialect.Family?] = [.mysql, .postgresql, .sqlite, .duckdb, nil]

/// The per-context keyword lists of analysis/autocomplete-spec.md 2.5, one context per line.
private let specContextKeywordLists = """
    SELECT list: DISTINCT, ALL, AS, FROM, CASE, WHEN, INTO, UNION, INTERSECT, EXCEPT
    SELECT in a function: DISTINCT, NULL, TRUE, FALSE
    FROM / JOIN: INNER JOIN, LEFT JOIN, RIGHT JOIN, FULL JOIN, LEFT OUTER JOIN, RIGHT OUTER JOIN, FULL OUTER JOIN, CROSS JOIN, NATURAL JOIN, JOIN, ON, USING, WHERE, ORDER BY, GROUP BY, HAVING, LIMIT, UNION, INTERSECT, EXCEPT
    INTO: VALUES, SELECT, SET
    ON: AND, OR, NOT, IS, NULL, TRUE, FALSE, WHERE, ORDER BY, GROUP BY, HAVING, LIMIT, UNION, INTERSECT, EXCEPT
    WHERE: AND, OR, NOT, IN, LIKE, ILIKE, BETWEEN, IS, NULL, NOT NULL, TRUE, FALSE, EXISTS, NOT EXISTS, ANY, ALL, SOME, REGEXP, RLIKE, SIMILAR TO, IS NULL, IS NOT NULL, ORDER BY, GROUP BY, HAVING, LIMIT, UNION, INTERSECT, EXCEPT
    GROUP BY: HAVING, ORDER BY, LIMIT, UNION, INTERSECT, EXCEPT
    ORDER BY: ASC, DESC, NULLS FIRST, NULLS LAST, LIMIT, OFFSET, UNION, INTERSECT, EXCEPT
    SET: WHERE, RETURNING
    VALUES: NULL, DEFAULT, TRUE, FALSE, ON CONFLICT, ON DUPLICATE KEY UPDATE, RETURNING
    CASE: WHEN, THEN, ELSE, END, AND, OR, IS, NULL, TRUE, FALSE
    IN list: SELECT, NULL, TRUE, FALSE
    LIMIT: OFFSET, FETCH, NEXT, ROWS, ONLY
    ALTER TABLE: ADD, DROP, MODIFY, CHANGE, RENAME, COLUMN, INDEX, PRIMARY, FOREIGN, KEY, CONSTRAINT, ENGINE, CHARSET, COLLATE, AUTO_INCREMENT, COMMENT, DEFAULT, CHARACTER SET, PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK
    CREATE TABLE columns: REFERENCES, ON DELETE, ON UPDATE, CASCADE, RESTRICT, SET NULL, NO ACTION, PRIMARY, KEY, FOREIGN, UNIQUE, NOT, NULL, DEFAULT, AUTO_INCREMENT, SERIAL, CHECK, CONSTRAINT, INDEX
    CREATE TABLE options: IF NOT EXISTS, ENGINE, CHARSET, COLLATE, COMMENT, TABLESPACE
    Column definition: NOT, NULL, DEFAULT, AUTO_INCREMENT, SERIAL, PRIMARY, KEY, UNIQUE, REFERENCES, CHECK, UNSIGNED, SIGNED, FIRST, AFTER, COMMENT, COLLATE, CHARACTER SET, ON UPDATE, ON DELETE, CASCADE, RESTRICT, SET NULL, NO ACTION
    UNION: SELECT, ALL
    Window: PARTITION BY, ORDER BY, ASC, DESC, ROWS, RANGE, GROUPS, BETWEEN, UNBOUNDED, PRECEDING, FOLLOWING, CURRENT ROW
    DROP object: IF EXISTS, CASCADE, RESTRICT
    CREATE INDEX: ON, USING, BTREE, HASH, GIN, GIST
    CREATE VIEW: SELECT, AS
    """

private func parsedSpecLists() -> [String: [String]] {
    var lists: [String: [String]] = [:]
    for line in specContextKeywordLists.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        let items = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        lists[String(parts[0])] = items
    }
    return lists
}

private func isSortedAndUnique(_ values: [String]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
}

@Suite struct SQLCompletionVocabularyTests {
    // MARK: - Statement start

    @Test(arguments: families)
    func statementStartIsTheSpecListForEveryDialect(family: SQLDialect.Family?) {
        let words = Vocabulary.statementStart(family)
        #expect(words.count == 31)
        #expect(Set(words).count == 31)
        #expect(words.first == "SELECT" && words.last == "PREPARE")
        #expect(words.contains("START TRANSACTION") && words.contains("UPSERT"))
    }

    // MARK: - Functions

    @Test func genericCatalogueHasTheSpecGroups() {
        let groups = Vocabulary.genericFunctionGroups
        #expect(groups.map(\.name) == ["Aggregate", "Date/time", "String", "Numeric", "Null handling", "Conversion", "Window", "JSON", "Session"])
        let sizes = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.functions.count) })
        #expect(sizes["Aggregate"] == 14)
        #expect(sizes["Null handling"] == 5)
        #expect(sizes["Conversion"] == 3)
        #expect(sizes["Window"] == 11)
        #expect(sizes["JSON"] == 20)
        #expect((36...42).contains(sizes["Date/time"] ?? 0))
        #expect((30...36).contains(sizes["String"] ?? 0))
        #expect((26...32).contains(sizes["Numeric"] ?? 0))
        #expect(Vocabulary.genericFunctions == groups.flatMap(\.functions))
        #expect(Vocabulary.genericFunctions.count == 161)
        let conversion = groups.first { $0.name == "Conversion" }?.functions.map(\.name)
        #expect(conversion == ["CAST", "CONVERT", "BINARY"])
    }

    @Test func genericSummariesNameTheDialectWhenSemanticsDiffer() {
        func summary(_ name: String) -> String { Vocabulary.genericFunctions.first { $0.name == name }?.summary ?? "" }
        #expect(summary("DAYOFWEEK").contains("MySQL") && summary("DAYOFWEEK").contains("DuckDB"))
        #expect(summary("DATEDIFF").contains("DuckDB"))
        #expect(summary("NVL").contains("MariaDB"))
    }

    @Test func genericFunctionsAreUniqueAndDocumented() {
        let functions = Vocabulary.genericFunctions
        #expect(Set(functions.map { $0.name.uppercased() }).count == functions.count)
        for entry in functions {
            #expect(entry.name == entry.name.uppercased())
            #expect(entry.signature.hasPrefix(entry.name))
            #expect(!(entry.summary ?? "").isEmpty, "\(entry.name) has no summary")
            #expect(!(entry.summary ?? "").contains("\n"))
        }
        for name in ["COUNT", "SUM", "AVG", "GROUP_CONCAT", "DATE_ADD", "TIMESTAMPDIFF", "TRUNCATE", "COALESCE", "ROW_NUMBER", "JSON_EXTRACT", "JSONB_SET"] {
            #expect(functions.contains { $0.name == name }, "missing \(name)")
        }
        #expect(functions.first { $0.name == "DATE_ADD" }?.signature == "DATE_ADD(date, INTERVAL expr unit)")
        #expect(functions.first { $0.name == "COUNT" }?.signature == "COUNT(expr)")
        #expect(functions.first { $0.name == "ROW_NUMBER" }?.signature.contains("OVER") == true)
    }

    @Test func onlySQLStandardNiladicFunctionsDropTheParentheses() {
        let niladic = Vocabulary.genericFunctions.filter(\.isNiladic)
        #expect(Set(niladic.map(\.name)) == [
            "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "LOCALTIME", "LOCALTIMESTAMP", "CURRENT_USER", "SESSION_USER", "USER",
        ])
        for entry in niladic {
            #expect(entry.signature == entry.name)
        }
        for entry in Vocabulary.genericFunctions where !entry.isNiladic {
            #expect(entry.signature.contains("("), "\(entry.name) should show its parentheses")
        }
        #expect(Vocabulary.genericFunctions.first { $0.name == "NOW" }?.isNiladic == false)
    }

    @Test func mysqlNeedsParenthesesOnUserAndSessionUser() {
        let mysql = Vocabulary.functions(.mysql)
        for name in ["USER", "SESSION_USER"] {
            let entry = mysql.first { $0.name == name }
            #expect(entry?.isNiladic == false)
            #expect(entry?.signature == name + "()")
        }
        #expect(mysql.first { $0.name == "CURRENT_USER" }?.isNiladic == true)
        #expect(mysql.first { $0.name == "CURRENT_DATE" }?.isNiladic == true)
        #expect(mysql.count == Vocabulary.genericFunctions.count + Vocabulary.dialectFunctions(.mysql).count)
        for family in [SQLDialect.Family.postgresql, .sqlite, .duckdb] {
            #expect(Vocabulary.functions(family) == Vocabulary.genericFunctions + Vocabulary.dialectFunctions(family))
        }
        #expect(Vocabulary.functions(nil) == Vocabulary.genericFunctions)
    }

    @Test(arguments: [
        (SQLDialect.Family.mysql, 90...150),
        (.postgresql, 400...480),
        (.sqlite, 45...80),
        (.duckdb, 150...250),
    ])
    func dialectFunctionsAreSortedUniqueAndNotGeneric(family: SQLDialect.Family, sizes: ClosedRange<Int>) {
        let functions = Vocabulary.dialectFunctions(family)
        #expect(sizes.contains(functions.count), "\(family) has \(functions.count) functions")
        let names = functions.map(\.name)
        #expect(isSortedAndUnique(names))
        let generic = Set(Vocabulary.genericFunctions.map { $0.name.uppercased() })
        for entry in functions {
            #expect(!generic.contains(entry.name.uppercased()), "\(entry.name) duplicates the generic catalogue")
            #expect(entry.name == entry.name.uppercased())
            #expect(entry.isNiladic ? entry.signature == entry.name : entry.signature.hasPrefix(entry.name + "("))
        }
    }

    @Test(arguments: [SQLDialect.Family.mysql, .postgresql, .sqlite, .duckdb])
    func dialectTablesHaveNoDuplicatesOrGenericNames(family: SQLDialect.Family) {
        let table: String
        switch family {
        case .mysql: table = Vocabulary.mysqlFunctionTable
        case .postgresql: table = Vocabulary.postgresqlFunctionTable
        case .sqlite: table = Vocabulary.sqliteFunctionTable
        case .duckdb: table = Vocabulary.duckdbFunctionTable
        }
        // Nothing in the raw table is silently dropped, so every line is a real extra.
        #expect(Vocabulary.parseFunctionTable(table).count == Vocabulary.dialectFunctions(family).count)
    }

    @Test(arguments: [SQLDialect.Family.mysql, .postgresql, .sqlite, .duckdb])
    func dialectFunctionsCarryAOneLineSummary(family: SQLDialect.Family) {
        for entry in Vocabulary.dialectFunctions(family) {
            let summary = entry.summary ?? ""
            #expect(!summary.isEmpty && !summary.contains("\n"), "\(family) \(entry.name) needs a one-line summary")
        }
    }

    @Test func dialectFunctionsHaveNoneWithoutADialect() {
        #expect(Vocabulary.dialectFunctions(nil).isEmpty)
    }

    @Test func dialectFunctionsIncludeTheNotableOnes() {
        func names(_ family: SQLDialect.Family) -> Set<String> { Set(Vocabulary.dialectFunctions(family).map(\.name)) }
        let duckdb = names(.duckdb)
        #expect(!Vocabulary.genericFunctions.contains { $0.name == "TRY_CAST" })
        for name in ["TRY_CAST", "READ_CSV", "READ_PARQUET", "READ_JSON", "LIST_VALUE", "LIST_FILTER", "STRUCT_PACK", "MAP", "UNNEST", "GENERATE_SERIES", "RANGE", "REGEXP_MATCHES", "EPOCH_MS"] {
            #expect(duckdb.contains(name), "DuckDB lacks \(name)")
        }
        let postgresql = names(.postgresql)
        for name in ["ARRAY_APPEND", "INT4RANGE", "JSONB_PATH_QUERY", "TO_TSVECTOR", "GEN_RANDOM_UUID", "PG_SIZE_PRETTY", "XPATH", "GENERATE_SERIES", "STRING_TO_ARRAY"] {
            #expect(postgresql.contains(name), "PostgreSQL lacks \(name)")
        }
        let sqlite = names(.sqlite)
        for name in ["TOTAL", "PRINTF", "JULIANDAY", "STRFTIME", "RANDOM", "TYPEOF", "HEX", "QUOTE"] {
            #expect(sqlite.contains(name), "SQLite lacks \(name)")
        }
        let mysql = names(.mysql)
        for name in ["IF", "FIND_IN_SET", "SUBSTRING_INDEX", "LAST_INSERT_ID", "JSON_TABLE", "UUID"] {
            #expect(mysql.contains(name), "MySQL lacks \(name)")
        }
        let catalog = Vocabulary.dialectFunctions(.postgresql).first { $0.name == "CURRENT_CATALOG" }
        #expect(catalog?.isNiladic == true && catalog?.signature == "CURRENT_CATALOG")
        #expect(Vocabulary.dialectFunctions(.duckdb).first { $0.name == "READ_PARQUET" }?.signature == "READ_PARQUET(path, …)")
    }

    @Test func barePlainNamesGetTheEllipsisSignature() {
        let entries = Vocabulary.parseFunctionTable("""
            # comment
            foo
            bar(a, b) | Does a thing
            now_ish | Moment
            """, niladic: ["NOW_ISH"])
        #expect(entries == [
            SQLFunctionEntry(name: "FOO", signature: "FOO(…)"),
            SQLFunctionEntry(name: "BAR", signature: "BAR(a, b)", summary: "Does a thing"),
            SQLFunctionEntry(name: "NOW_ISH", signature: "NOW_ISH", summary: "Moment", isNiladic: true),
        ])
    }

    // MARK: - Operators

    @Test func genericOperatorsAreTheEightComparisons() {
        #expect(Vocabulary.genericOperators.map(\.symbol) == ["=", "<>", "!=", "<", ">", "<=", ">=", "<=>"])
        #expect(Vocabulary.genericOperators.allSatisfy { !($0.summary ?? "").isEmpty && $0.types == nil })
    }

    @Test func onlyPostgreSQLDeclaresDialectOperators() {
        let operators = Vocabulary.dialectOperators(.postgresql)
        #expect((50...60).contains(operators.count))
        #expect(Set(operators.map(\.symbol)).count == operators.count)
        #expect(operators.allSatisfy { !($0.summary ?? "").isEmpty && !($0.types ?? "").isEmpty })
        let symbols = Set(operators.map(\.symbol))
        for symbol in ["::", "IS DISTINCT FROM", "IS NOT DISTINCT FROM", "IS NULL", "IS NOT NULL", "BETWEEN SYMMETRIC", "||", "^@", "~*", "!~~*", "->", "->>", "#>>", "@>", "<@", "?|", "?&", "#-", "@?", "@@", "&&", "-|-", "<->", "!!", "<<=", ">>=", "|/", "||/"] {
            #expect(symbols.contains(symbol), "missing \(symbol)")
        }
        #expect(operators.first { $0.symbol == "@>" }?.types?.contains("array") == true)
        // ON and CASE have no IS NULL phrase, so these stay; the engine skips them where WHERE already has them.
        let whereKeywords = Set(parsedSpecLists()["WHERE"] ?? [])
        #expect(symbols.intersection(whereKeywords) == ["IS NULL", "IS NOT NULL"])
        #expect(!(parsedSpecLists()["ON"] ?? []).contains("IS NULL") && !(parsedSpecLists()["CASE"] ?? []).contains("IS NULL"))
        for family in [SQLDialect.Family.mysql, .sqlite, .duckdb] {
            #expect(Vocabulary.dialectOperators(family).isEmpty)
        }
        #expect(Vocabulary.dialectOperators(nil).isEmpty)
    }

    // MARK: - Data types

    @Test(arguments: [
        (SQLDialect.Family?.some(.mysql), 30...38),
        (.some(.postgresql), 85...95),
        (.some(.sqlite), 26...32),
        (.some(.duckdb), 40...46),
        (nil, 22...22),
    ])
    func dataTypesAreSortedAndUnique(family: SQLDialect.Family?, sizes: ClosedRange<Int>) {
        let types = Vocabulary.dataTypes(family)
        #expect(sizes.contains(types.count), "\(String(describing: family)) has \(types.count) types")
        #expect(isSortedAndUnique(types))
        #expect(types.allSatisfy { $0 == $0.uppercased() })
    }

    @Test func dataTypesCarryTheDialectSpecifics() {
        let mysql = Set(Vocabulary.dataTypes(.mysql))
        for type in ["ENUM", "SET", "YEAR", "MEDIUMINT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB", "JSON"] {
            #expect(mysql.contains(type), "MySQL lacks \(type)")
        }
        let postgresql = Set(Vocabulary.dataTypes(.postgresql))
        for type in ["JSONB", "JSONPATH", "TIMESTAMPTZ", "TIMESTAMP WITH TIME ZONE", "DOUBLE PRECISION", "CHARACTER VARYING", "SERIAL", "BIGSERIAL", "BYTEA", "INT4RANGE", "TSTZMULTIRANGE", "INET", "CIDR", "MACADDR", "REGCLASS", "TSVECTOR", "UUID"] {
            #expect(postgresql.contains(type), "PostgreSQL lacks \(type)")
        }
        let sqlite = Set(Vocabulary.dataTypes(.sqlite))
        #expect(!sqlite.contains("JSONB"))
        for type in ["INT2", "INT8", "CHARACTER", "VARYING", "NATIVE", "PRECISION", "UNSIGNED", "BIG", "CLOB"] {
            #expect(sqlite.contains(type), "SQLite lacks \(type)")
        }
        let duckdb = Set(Vocabulary.dataTypes(.duckdb))
        for type in ["HUGEINT", "UHUGEINT", "TIMESTAMP WITH TIME ZONE", "INTERVAL", "LIST", "MAP", "STRUCT", "UNION", "ENUM", "BIT"] {
            #expect(duckdb.contains(type), "DuckDB lacks \(type)")
        }
        // Aliases people bring from other engines; the no-dialect fallback must not offer more than DuckDB does.
        for type in ["TEXT", "INT", "BOOL", "NUMERIC", "REAL", "DATETIME", "TIMETZ", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS", "STRING"] {
            #expect(duckdb.contains(type), "DuckDB lacks the alias \(type)")
        }
        #expect(Set(Vocabulary.dataTypes(nil)) == [
            "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL", "VARCHAR",
            "CHAR", "TEXT", "DATE", "TIME", "DATETIME", "TIMESTAMP", "BOOLEAN", "BOOL", "BLOB", "JSON", "UUID",
        ])
    }

    @Test func castTargetsAreLowercaseRealTypes() {
        let types = Vocabulary.castTargetTypes(.postgresql)
        #expect(isSortedAndUnique(types))
        #expect(types.allSatisfy { $0 == $0.lowercased() })
        #expect(types.contains("jsonb") && types.contains("timestamptz") && types.contains("double precision"))
        #expect(!types.contains("serial") && !types.contains("bigserial"))
        #expect(Vocabulary.castTargetTypes(.postgresql).count == Vocabulary.dataTypes(.postgresql).count - 6)
        let duckdb = Vocabulary.castTargetTypes(.duckdb)
        #expect(duckdb.contains("hugeint") && duckdb.contains("timestamp_ns") && duckdb.contains("text"))
        // DuckDB's nested types and ENUM need parameters, so a bare `::struct` fails.
        for type in ["enum", "list", "map", "struct", "union"] {
            #expect(!duckdb.contains(type), "DuckDB cast offers bare \(type)")
        }
        #expect(Vocabulary.castTargetTypes(.duckdb).count == Vocabulary.dataTypes(.duckdb).count - 5)
    }

    // MARK: - Table options

    @Test func tableOptionsFollowTheDialect() {
        #expect(Vocabulary.tableOptions(.mysql) == ["ENGINE=InnoDB", "DEFAULT CHARSET=utf8mb4", "COLLATE=utf8mb4_unicode_ci", "AUTO_INCREMENT=", "COMMENT=", "ROW_FORMAT="])
        #expect(Vocabulary.tableOptions(.postgresql) == ["INHERITS", "PARTITION BY", "TABLESPACE", "WITH", "WITHOUT OIDS"])
        #expect(Vocabulary.tableOptions(.sqlite) == ["WITHOUT ROWID", "STRICT"])
        #expect(Vocabulary.tableOptions(.duckdb) == [])
        #expect(Vocabulary.tableOptions(nil) == nil)
    }

    // MARK: - Keywords

    @Test func keywordDocumentationCoversTheCommonKeywords() {
        let docs = Vocabulary.keywordDocumentation
        #expect((65...110).contains(docs.count))
        for (keyword, text) in docs {
            #expect(keyword == keyword.uppercased())
            #expect(!text.isEmpty && !text.contains("\n"), "\(keyword) needs a one-line description")
        }
        let required = [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "LEFT OUTER JOIN",
            "RIGHT OUTER JOIN", "FULL OUTER JOIN", "CROSS JOIN", "NATURAL JOIN", "GROUP BY", "ORDER BY", "HAVING", "LIMIT",
            "OFFSET", "UNION", "IS NULL", "IS NOT NULL", "IN", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "DISTINCT", "AS", "ON",
            "USING", "RETURNING", "ON CONFLICT", "ON DUPLICATE KEY UPDATE", "PARTITION BY", "NULLS FIRST", "NULLS LAST",
            "ASC", "DESC", "VALUES", "SET", "CASE", "WHEN", "THEN", "ELSE", "END",
        ]
        for keyword in required {
            #expect(docs[keyword] != nil, "no documentation for \(keyword)")
        }
    }

    /// Docs are keyed by text alone, so a keyword offered in two contexts gets one line that fits both.
    @Test func keywordDocumentationFitsEveryContextTheWordAppearsIn() {
        let docs = Vocabulary.keywordDocumentation
        #expect(docs["DESC"]?.contains("describes a table") == true)
        #expect(docs["ROWS"]?.contains("FETCH") == true)
        #expect(docs["ON"]?.contains("index") == true)
        #expect(docs["USING"]?.contains("index") == true)
        #expect(docs["WITH"]?.contains("storage") == true)
        #expect(docs["PARTITION BY"]?.contains("table") == true)
        #expect(docs["INTO"]?.contains("SELECT") == true)
    }

    @Test func masterKeywordsAreSingleUppercaseWords() {
        let keywords = Vocabulary.masterKeywords
        #expect((280...340).contains(keywords.count), "\(keywords.count) master keywords")
        for keyword in keywords {
            #expect(keyword == keyword.uppercased() && !keyword.contains(" ") && !keyword.isEmpty)
        }
        for extra in ["RETURNING", "LATERAL", "CONCURRENTLY", "CONFLICT", "EXCLUDED", "ILIKE", "STRAIGHT_JOIN", "FORCE", "USE", "SIGNED", "UNSIGNED", "REGEXP", "RLIKE", "GRANT", "REVOKE"] {
            #expect(keywords.contains(extra), "missing \(extra)")
        }
    }

    @Test func masterKeywordsCoverEveryWordCompletionOffers() {
        let lists = parsedSpecLists()
        #expect(lists.count == 22)
        var phrases = lists.values.flatMap { $0 }
        phrases += families.flatMap { Vocabulary.statementStart($0) }
        phrases += families.flatMap { Vocabulary.dataTypes($0) }
        // Table options: only the keyword part before `=` (values such as InnoDB are not keywords).
        phrases += families.flatMap { Vocabulary.tableOptions($0) ?? [] }.map { String($0.prefix { $0 != "=" }) }
        let words = Set(phrases.flatMap { $0.split(separator: " ").map(String.init) })
        let missing = words.subtracting(Vocabulary.masterKeywords).subtracting(Vocabulary.identifierLikeTypeWords)
        #expect(missing.isEmpty, "not in masterKeywords: \(missing.sorted())")
        // Every exclusion is a real type word, so the list does not rot.
        #expect(Vocabulary.identifierLikeTypeWords.isSubset(of: words))
    }

    /// Re-casing these would break a table of that name on MySQL servers with case-sensitive table names.
    @Test func masterKeywordsLeaveIdentifierLikeWordsAlone() {
        let keywords = Vocabulary.masterKeywords
        #expect(keywords.isDisjoint(with: Vocabulary.identifierLikeTypeWords))
        for word in ["ROLE", "LEVEL", "WORK", "ZONE", "NAME", "YEAR", "POINT", "MONEY"] {
            #expect(!keywords.contains(word), "\(word) would be re-cased")
        }
        for word in ["MEDIUMTEXT", "LONGTEXT", "TINYBLOB", "VARBINARY", "TIMESTAMPTZ", "JSONPATH", "BIGSERIAL", "INT8", "HUGEINT", "UBIGINT", "TSVECTOR", "ENUM"] {
            #expect(keywords.contains(word), "missing type word \(word)")
        }
    }

    // MARK: - Reserved words

    @Test(arguments: families)
    func reservedWordsLeaveCommonColumnNamesBare(family: SQLDialect.Family?) {
        let reserved = Vocabulary.reservedWords(family)
        #expect(reserved.allSatisfy { $0 == $0.uppercased() && !$0.contains(" ") })
        #expect(reserved.isSuperset(of: ["SELECT", "FROM", "WHERE", "ORDER", "GROUP", "TABLE", "AND", "NULL"]))
        for name in ["DATE", "NAME", "COMMENT", "STATUS", "TEXT", "TIME", "TIMESTAMP", "TYPE", "LEVEL", "ACTION", "VALUE", "DATA", "FIRST", "LAST"] {
            #expect(!reserved.contains(name), "\(String(describing: family)) would quote a column named \(name.lowercased())")
        }
    }

    @Test func reservedWordsFollowTheDialect() {
        #expect(Vocabulary.reservedWords(.mysql).isSuperset(of: ["KEY", "RANGE", "RANK", "INTERVAL", "STRAIGHT_JOIN", "SET"]))
        // information_schema calls these unreserved, but MySQL 8.4 rejects them bare.
        #expect(Vocabulary.reservedWords(.mysql).isSuperset(of: ["CUBE", "MANUAL", "PARALLEL", "QUALIFY", "TABLESAMPLE", "SQL_NO_CACHE", "SQL_BUFFER_RESULT"]))
        // MariaDB shares the family and reserves a few more.
        #expect(Vocabulary.reservedWords(.mysql).isSuperset(of: ["RETURNING", "OFFSET", "CURRENT_ROLE", "VECTOR", "STATS_PERSISTENT"]))
        // MySQL 8.0 still reserves MASTER_BIND.
        #expect(Vocabulary.reservedWords(.mysql).contains("MASTER_BIND"))
        #expect(Vocabulary.reservedWords(.mysql) == Vocabulary.mysqlCatalogueReservedWords
            .union(Vocabulary.mysqlUnlistedReservedWords)
            .union(Vocabulary.mysql80ReservedWords)
            .union(Vocabulary.mariadbReservedWords))
        #expect(Vocabulary.mysqlCatalogueReservedWords.isDisjoint(with: Vocabulary.mysqlUnlistedReservedWords))
        #expect(Vocabulary.mysqlCatalogueReservedWords.isDisjoint(with: Vocabulary.mariadbReservedWords))
        #expect(Vocabulary.reservedWords(.postgresql).isSuperset(of: ["USER", "ILIKE", "LIMIT", "OFFSET", "RETURNING"]))
        #expect(!Vocabulary.reservedWords(.postgresql).contains("SET") && !Vocabulary.reservedWords(.postgresql).contains("KEY"))
        #expect(Vocabulary.reservedWords(.duckdb).isSuperset(of: ["QUALIFY", "PIVOT", "ASOF", "ILIKE"]))
        #expect(Vocabulary.reservedWords(.sqlite).isSuperset(of: ["SET", "VALUES", "INDEX", "CURRENT_DATE"]))
        #expect(!Vocabulary.reservedWords(.sqlite).contains("LEFT") && !Vocabulary.reservedWords(.sqlite).contains("KEY"))
        let everywhere = [SQLDialect.Family.postgresql, .sqlite, .duckdb]
            .map { Vocabulary.reservedWords($0) }
            .reduce(Vocabulary.reservedWords(.mysql)) { $0.intersection($1) }
        #expect(Vocabulary.reservedWords(nil) == everywhere)
        #expect(!Vocabulary.reservedWords(nil).contains("KEY") && Vocabulary.reservedWords(nil).contains("UNION"))
    }
}

// MARK: - Live catalogues

/// Checks names against the engines' own catalogues, so a typo or an engine-specific name cannot slip in.
@Suite("SQL vocabulary against live engines", .serialized)
struct SQLCompletionVocabularyLiveTests {
    private static func values(_ session: DatabaseSession, _ sql: String) async throws -> Set<String> {
        let results = try await session.execute(sql)
        return Set(results.flatMap(\.rows).compactMap { $0.first?.textValue?.lowercased() })
    }

    private static func open(_ config: ConnectionConfig, password: String = "") async throws -> DatabaseSession {
        let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: password))
        try await session.connect()
        return session
    }

    private static func lowercasedNames(_ family: SQLDialect.Family) -> [String] {
        Vocabulary.dialectFunctions(family).map { $0.name.lowercased() }
    }

    /// Words that do not work as a bare table and column name: in CREATE, INSERT, UPDATE, as the first SELECT item,
    /// in ORDER BY and as a qualified column. A read that returns something other than the stored value (the clock,
    /// say) counts as a failure too.
    private static func bareNameFailures(_ session: DatabaseSession, _ words: Set<String>, create: String, drop: String, quote: Character) async -> Set<String> {
        var failures = Set<String>()
        for word in words.sorted() {
            let name = word.lowercased()
            do {
                _ = try await session.execute("\(create) \(name) (\(name) INT)")
                _ = try await session.execute("INSERT INTO \(name) (\(name)) VALUES (7)")
                _ = try await session.execute("UPDATE \(name) SET \(name) = 7 WHERE \(name) = 7")
                let plain = try await values(session, "SELECT \(name) FROM \(name) ORDER BY \(name)")
                let qualified = try await values(session, "SELECT t.\(name) FROM \(name) t WHERE \(name) > 0")
                if plain != ["7"] || qualified != ["7"] { failures.insert(word) }
            } catch {
                failures.insert(word)
            }
            _ = try? await session.execute("\(drop) \(quote)\(name)\(quote)")
        }
        return failures
    }

    /// Types that a bare `NULL::type` rejects.
    private static func uncastable(_ session: DatabaseSession, _ types: [String]) async -> [String] {
        var failures: [String] = []
        for type in types {
            do { _ = try await session.execute("SELECT NULL::\(type)") } catch { failures.append(type) }
        }
        return failures
    }

    @Test func duckdbNamesExist() async throws {
        let session = try await Self.open(ConnectionConfig(kind: .duckdb, filePath: ""))
        let functions = try await Self.values(session, "SELECT DISTINCT function_name FROM duckdb_functions()")
        // Written with special SQL syntax, so duckdb_functions() has no entry under these names.
        let syntaxForms: Set<String> = ["try_cast"]
        let missing = Self.lowercasedNames(.duckdb).filter { !functions.contains($0) && !syntaxForms.contains($0) }
        #expect(missing.isEmpty, "unknown DuckDB functions: \(missing)")
        _ = try await session.execute("SELECT TRY_CAST('x' AS INTEGER)")
        let types = try await Self.values(session, "SELECT DISTINCT type_name FROM duckdb_types()")
        let missingTypes = Vocabulary.dataTypes(.duckdb).filter { !types.contains($0.lowercased()) }
        #expect(missingTypes.isEmpty, "unknown DuckDB types: \(missingTypes)")
        let reserved = try await Self.values(session, """
            SELECT keyword_name FROM duckdb_keywords() WHERE keyword_category IN ('reserved', 'type_function')
            """)
        #expect(Set(Vocabulary.reservedWords(.duckdb).map { $0.lowercased() }) == reserved)
        await session.close()
    }

    @Test func duckdbCastTargetsCast() async throws {
        let session = try await Self.open(ConnectionConfig(kind: .duckdb, filePath: ""))
        let failures = await Self.uncastable(session, Vocabulary.castTargetTypes(.duckdb))
        #expect(failures.isEmpty, "DuckDB rejects these casts: \(failures)")
        // The ones left out really need parameters.
        let excluded = Vocabulary.dataTypes(.duckdb).filter { Vocabulary.castExcludedTypes.contains($0) }.map { $0.lowercased() }
        #expect(await Self.uncastable(session, excluded) == excluded)
        await session.close()
    }

    /// DuckDB's dayofweek counts from 0, unlike MySQL's; the shared summary says so.
    @Test func duckdbDayOfWeekStartsAtZero() async throws {
        let session = try await Self.open(ConnectionConfig(kind: .duckdb, filePath: ""))
        #expect(try await Self.values(session, "SELECT dayofweek(DATE '2024-01-07')") == ["0"])
        await session.close()
    }

    /// SQLite has no keyword catalogue in SQL, so every keyword we know is tried as a table and column name.
    /// CURRENT_DATE/TIME/TIMESTAMP parse as names, but a bare reference yields the clock, so they count as rejected.
    @Test func sqliteReservedWordsAreTheOnesItRejectsAsNames() async throws {
        let session = try await Self.open(ConnectionConfig(kind: .sqlite, filePath: ":memory:"))
        let candidates = Vocabulary.masterKeywords
            .union(Vocabulary.reservedWords(.sqlite))
            .union(Vocabulary.reservedWords(.postgresql))
        let rejected = await Self.bareNameFailures(session, candidates, create: "CREATE TABLE", drop: "DROP TABLE IF EXISTS", quote: "\"")
        #expect(rejected == Vocabulary.reservedWords(.sqlite), "extra: \(rejected.subtracting(Vocabulary.reservedWords(.sqlite)).sorted()), unneeded: \(Vocabulary.reservedWords(.sqlite).subtracting(rejected).sorted())")
        await session.close()
    }

    @Test func sqliteNamesExist() async throws {
        let session = try await Self.open(ConnectionConfig(kind: .sqlite, filePath: ":memory:"))
        let functions = try await Self.values(session, "SELECT DISTINCT name FROM pragma_function_list")
        // Table-valued functions are virtual tables, not entries of pragma_function_list.
        let tableValued: Set<String> = ["json_each", "json_tree"]
        let missing = Self.lowercasedNames(.sqlite).filter { !functions.contains($0) && !tableValued.contains($0) }
        #expect(missing.isEmpty, "unknown SQLite functions: \(missing)")
        for name in tableValued {
            _ = try await session.execute("SELECT * FROM \(name)('[1]')")
        }
        await session.close()
    }

    @Test(.enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
    func postgresqlNamesExist() async throws {
        let config = ConnectionConfig(kind: .postgresql, host: PostgresTestServer.host, port: PostgresTestServer.port, user: "postgres", database: "foxlume", sslMode: .prefer)
        let session = try await Self.open(config, password: "postgres")
        // The vocabulary follows PostgreSQL 18. Older servers lack some of its functions, types and keywords, which
        // completion still offers there; on them only check that every word the server reserves gets quoted.
        let current = (Int(session.serverVersion.prefix { $0.isNumber }) ?? 0) >= 18
        let functions = try await Self.values(session, """
            SELECT DISTINCT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pg_catalog'
            """)
        // Written with special SQL syntax, so pg_proc has no entry under these names.
        let syntaxForms: Set<String> = [
            "current_catalog", "current_role", "json_exists", "json_query", "json_scalar", "json_serialize", "json_table", "json_value",
            "xmlconcat", "xmlelement", "xmlforest", "xmlparse", "xmlpi", "xmlroot", "xmlserialize", "xmltable",
        ]
        if current {
            let missing = Self.lowercasedNames(.postgresql).filter { !functions.contains($0) && !syntaxForms.contains($0) }
            #expect(missing.isEmpty, "unknown PostgreSQL functions: \(missing)")

            let candidates = Vocabulary.dataTypes(.postgresql).filter { !Vocabulary.castExcludedTypes.contains($0) }
            let list = candidates.map { SQLDialect.postgresql.quoteString($0.lowercased()) }.joined(separator: ", ")
            let unknownTypes = try await Self.values(session, "SELECT t FROM unnest(ARRAY[\(list)]) AS t WHERE to_regtype(t) IS NULL")
            #expect(unknownTypes.isEmpty, "unknown PostgreSQL types: \(unknownTypes.sorted())")
            let uncastable = await Self.uncastable(session, Vocabulary.castTargetTypes(.postgresql))
            #expect(uncastable.isEmpty, "PostgreSQL rejects these casts: \(uncastable)")
        }

        // R is fully reserved; T may name a function or type but not a column or table.
        let reserved = try await Self.values(session, "SELECT word FROM pg_get_keywords() WHERE catcode IN ('R', 'T')")
        let quoted = Set(Vocabulary.reservedWords(.postgresql).map { $0.lowercased() })
        if current {
            #expect(quoted == reserved)
        } else {
            #expect(quoted.isSuperset(of: reserved), "not quoted: \(reserved.subtracting(quoted).sorted())")
        }
        await session.close()
    }

    @Test(.enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
    func mysqlNamesAreDocumentedByTheServer() async throws {
        let session = DatabaseSession(parameters: MySQLTestServer.parameters())
        try await session.connect()
        let topics = try await Self.values(session, "SELECT name FROM mysql.help_topic")
        try #require(!topics.isEmpty, "the server has no help tables loaded")
        // Help topics name some functions with a suffix ("IF FUNCTION", "MATCH AGAINST", "JSON_MERGE_PATCH()").
        let normalized = Set(topics.map { topic in
            topic.replacingOccurrences(of: " function", with: "").replacingOccurrences(of: " against", with: "").replacingOccurrences(of: "()", with: "")
        })
        let missing = Self.lowercasedNames(.mysql).filter { !normalized.contains($0) }
        #expect(missing.isEmpty, "MySQL functions without a help topic: \(missing)")
        // The generic Conversion group's BINARY still runs, and USER needs its parentheses.
        _ = try await session.execute("SELECT BINARY('a') = 'a', USER(), SESSION_USER()")
        await #expect(throws: (any Error).self) { _ = try await session.execute("SELECT USER") }
        await session.close()
    }

    @Test(.enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
    func mysqlReservedWordsCoverTheServer() async throws {
        let session = DatabaseSession(parameters: MySQLTestServer.parameters())
        try await session.connect()
        let quoted = Set(Vocabulary.reservedWords(.mysql).map { $0.lowercased() })
        let reserved = try await Self.values(session, "SELECT WORD FROM information_schema.KEYWORDS WHERE RESERVED = 1")
        #expect(quoted.isSuperset(of: reserved), "not quoted: \(reserved.subtracting(quoted).sorted())")

        // The catalogue under-reports, so every unreserved keyword is tried as a bare name too.
        let unreserved = try await Self.values(session, "SELECT WORD FROM information_schema.KEYWORDS WHERE RESERVED = 0")
        let candidates = Set(unreserved.map { $0.uppercased() }).union(Vocabulary.mysqlUnlistedReservedWords)
        let rejected = await Self.bareNameFailures(session, candidates, create: "CREATE TEMPORARY TABLE", drop: "DROP TEMPORARY TABLE IF EXISTS", quote: "`")
        #expect(rejected.isSubset(of: Vocabulary.reservedWords(.mysql)), "rejected but inserted bare: \(rejected.subtracting(Vocabulary.reservedWords(.mysql)).sorted())")
        // Which of the others a server rejects changes between releases (8.4.9 rejects them all, 8.4.13 takes MANUAL and
        // PARALLEL as bare names, 8.0 also QUALIFY and TABLESAMPLE); quoting a word a server accepts is harmless.
        let rejectedEverywhere: Set<String> = ["CUBE", "SQL_BUFFER_RESULT", "SQL_NO_CACHE"]
        #expect(rejectedEverywhere.isSubset(of: Vocabulary.mysqlUnlistedReservedWords))
        #expect(rejectedEverywhere.isSubset(of: rejected), "listed but accepted: \(rejectedEverywhere.subtracting(rejected).sorted())")
        await session.close()
    }
}
