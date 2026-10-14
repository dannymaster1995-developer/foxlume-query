import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Analyzer-level checks for spec 1.3 and 2–3. `|` marks the caret.
@Suite struct SQLContextAnalyzerTests {
    func analyze(_ marked: String, _ family: SQLDialect.Family? = .mysql) -> SQLCompletionContext? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return SQLContextAnalyzer.analyze(text: text, caret: caret, family: family)
    }

    func clause(_ marked: String, _ family: SQLDialect.Family? = .mysql) -> SQLClause? {
        analyze(marked, family)?.clause
    }

    // MARK: Suppression (1.3)

    @Test func statementBreakSuppresses() {
        #expect(analyze("SELECT 1;|") == nil)
        #expect(analyze("SELECT 1;|  \n ") == nil)
        #expect(analyze("SELECT 1\n|") == nil)
        #expect(analyze("SELECT 1;| SELECT 2") != nil)
        #expect(analyze("SELECT 1\n|FROM t") != nil)
    }

    @Test func stringsAndCommentsSuppress() {
        #expect(analyze("SELECT * FROM users WHERE name = 'Jo|") == nil)
        #expect(analyze("SELECT * FROM users WHERE name = 'it''s |") == nil)
        #expect(analyze("SELECT * FROM users WHERE name = 'it''s' AND |") != nil)
        #expect(analyze("SELECT * FROM users WHERE name = 'a\\'b |") == nil)
        #expect(analyze("SELECT * FROM users -- comm|") == nil)
        #expect(analyze("SELECT * FROM users -- note\nWHERE |") != nil)
        #expect(analyze("SELECT /* open |") == nil)
        #expect(analyze("SELECT /* a */ |") != nil)
        #expect(analyze("SELECT * FROM t # note |", .mysql) == nil)
        #expect(analyze("SELECT $$ body |", .postgresql) == nil)
    }

    @Test func nestedBlockCommentsAreCounted() {
        let context = analyze("/* outer /* inner */ still */SELECT |")
        #expect(context?.clause == .selectList)
        #expect(analyze("/* outer /* inner */ still |") == nil)
    }

    @Test func doubleQuoteIsAnIdentifierOutsideMySQL() {
        // MySQL (and no dialect) read "…" as a string; the others as an identifier being typed (A.1).
        #expect(analyze("SELECT * FROM \"cat|", .mysql) == nil)
        #expect(analyze("SELECT * FROM \"cat|", nil) == nil)
        let pg = analyze("SELECT * FROM \"my cat|", .postgresql)
        #expect(pg?.token == "\"my cat")
        #expect(pg?.prefix == "my cat")
        #expect(pg?.clause == .from)
        #expect(analyze("SELECT * FROM `cat|", .mysql)?.prefix == "cat")
    }

    // MARK: Token, prefix, qualifier (2.3)

    @Test func tokenPrefixAndReplacementRange() throws {
        let context = try #require(analyze("SELECT * FROM `cat|"))
        #expect(context.token == "`cat")
        #expect(context.prefix == "cat")
        #expect(context.replacementRange == NSRange(location: 14, length: 4))
        let closed = try #require(analyze("SELECT * FROM `cat`|"))
        #expect(closed.prefix == "cat")
        let lone = try #require(analyze("SELECT * FROM `|"))
        #expect(lone.token == "`" && lone.prefix == "")
        let middle = try #require(analyze("SELECT na|me"))
        #expect(middle.token == "na" && middle.replacementRange == NSRange(location: 7, length: 2))
    }

    @Test func nonASCIITokens() throws {
        let cjk = try #require(analyze("SELECT 名|"))
        #expect(cjk.token == "名" && cjk.replacementRange == NSRange(location: 7, length: 1))
        let combining = try #require(analyze("SELECT cafe\u{301}|"))
        #expect(combining.token == "cafe\u{301}")
        #expect(try #require(analyze("SELECT a→b|")).token == "b")
        #expect(try #require(analyze("SELECT x、y|")).token == "y")
        #expect(try #require(analyze("SELECT 😀ab|")).token == "ab")
        #expect(try #require(analyze("SELECT a$b|")).token == "b")
    }

    @Test func qualifierKeepsOneLevel() throws {
        let context = try #require(analyze("SELECT public.users.na|"))
        #expect(context.qualifier == "users" && context.prefix == "na")
        #expect(try #require(analyze("SELECT `mydb`.`users`.n|")).qualifier == "users")
        #expect(try #require(analyze("SELECT \"my table\".|", .postgresql)).qualifier == "my table")
        #expect(try #require(analyze("SELECT u.| FROM users u")).clause == .selectList)
        #expect(try #require(analyze("SELECT 1|")).qualifier == nil)
    }

    @Test func castOverride() throws {
        let context = try #require(analyze("SELECT id::js|", .postgresql))
        #expect(context.clause == .castTarget && context.prefix == "js" && context.qualifier == nil)
        #expect(clause("SELECT id::|", .postgresql) == .castTarget)
    }

    @Test func afterComma() throws {
        #expect(try #require(analyze("SELECT id, |")).isAfterComma)
        #expect(try #require(analyze("SELECT id,|")).isAfterComma)
        #expect(try #require(analyze("SELECT id, n|")).isAfterComma == false)
        #expect(try #require(analyze("SELECT id |")).isAfterComma == false)
    }

    // MARK: Statements (2.1)

    @Test func secondStatementIsAnalyzed() throws {
        let text = "SELECT 1; SELECT * FROM |"
        let context = try #require(analyze(text))
        #expect(context.clause == .from && context.expectsObjectName)
        #expect(context.statementRange.location == 9)
        let semicolonInString = try #require(analyze("SELECT ';' AS x FROM |"))
        #expect(semicolonInString.clause == .from)
    }

    @Test func routineBodiesDoNotSplit() throws {
        let text = "CREATE PROCEDURE p() BEGIN SELECT 1; IF x THEN SELECT 2; END IF; SELECT * FROM |"
        let context = try #require(analyze(text))
        #expect(context.statementRange.location == 0)
        #expect(context.clause == .from)
    }

    @Test func windowAroundCaret() throws {
        let filler = String(repeating: "SELECT 1 FROM dual WHERE a = 'x';\n", count: 400)
        let text = filler + "SELECT * FROM users u WHERE u."
        let context = try #require(SQLContextAnalyzer.analyze(text: text, caret: (text as NSString).length, family: .mysql))
        #expect(context.qualifier == "u")
        #expect(context.references.map(\.table) == ["users"])
        #expect(context.replacementRange.location == (text as NSString).length)
    }

    // MARK: Structural rules (2.4 step 2)

    @Test func alterTableRules() {
        #expect(clause("ALTER TABLE users ADD COLUMN email VARCHAR(255) AFTER |") == .alterTableColumn)
        #expect(clause("ALTER TABLE users ADD x INT BEFORE |") == .alterTableColumn)
        #expect(clause("ALTER TABLE users ADD x INT FIRST |") == .alterTable)
        #expect(clause("ALTER TABLE users ADD CONSTRAINT |") == .alterTable)
        #expect(clause("ALTER TABLE users ADD |") == .alterTable)
        #expect(clause("ALTER TABLE users ADD COLUMN email VARCHAR(255) NOT NULL DEFAULT 'x' |") == .columnDefinition)
        #expect(clause("ALTER TABLE users MODIFY COLUMN age INT UNSIGNED |") == .columnDefinition)
        #expect(clause("ALTER TABLE users ADD COLUMN email |") == .columnDefinition)
        #expect(clause("ALTER TABLE users DROP COLUMN |") == .alterTableColumn)
        #expect(clause("ALTER TABLE users RENAME |") == .alterTableColumn)
        #expect(clause("ALTER TABLE users |") == .alterTable)
        #expect(clause("ALTER TABLE users ADD x INT, |") == .alterTable)
        #expect(clause("ALTER TABLE users ADD x INT, DROP COLUMN |") == .alterTableColumn)
        // FIRST outside ALTER is not rule 3.
        #expect(clause("SELECT * FROM t ORDER BY a NULLS FIRST |") == .orderBy)
        #expect(analyze("ALTER TABLE app.users DROP COLUMN |")?.targetTable == SQLTableReference(schema: "app", table: "users"))
    }

    @Test func createTableRules() throws {
        let inside = try #require(analyze("CREATE TABLE test (id |"))
        #expect(inside.clause == .createTable && inside.insideCreateTableColumns && inside.nestingLevel == 1)
        // The column list stays tracked after a nested paren closes (A.5).
        let afterType = try #require(analyze("CREATE TABLE test (name VARCHAR(255), |"))
        #expect(afterType.clause == .createTable && afterType.insideCreateTableColumns)
        let outside = try #require(analyze("CREATE TABLE test (id INT) ENG|"))
        #expect(outside.clause == .createTable && !outside.insideCreateTableColumns)
        #expect(clause("CREATE TABLE |") == .createTable)
        #expect(clause("CREATE TEMPORARY TABLE IF NOT EXISTS |") == .createTable)
        #expect(clause("CREATE TABLE t AS SELECT * FROM |") == .from)
    }

    @Test func dropAndIndexAndViewRules() throws {
        let drop = try #require(analyze("DROP TABLE IF EXISTS |"))
        #expect(drop.clause == .dropObject && drop.expectsObjectName)
        #expect(clause("DROP VIEW |") == .dropObject)
        #expect(clause("DROP TABLE a, |") == .dropObject)
        #expect(clause("CREATE INDEX |") == .createIndex)
        #expect(clause("CREATE UNIQUE INDEX idx |") == .createIndex)
        // A.6: the table position after ON is CREATE INDEX (tables), not the ON clause.
        let onTable = try #require(analyze("CREATE INDEX idx ON |"))
        #expect(onTable.clause == .createIndex && onTable.nestingLevel == 0)
        let columns = try #require(analyze("CREATE INDEX idx ON users (|"))
        #expect(columns.clause == .createIndex && columns.nestingLevel == 1)
        #expect(columns.references.map(\.table) == ["users"])
        #expect(clause("CREATE INDEX idx ON users USING gin (|", .postgresql) == .createIndex)
        #expect(clause("CREATE OR REPLACE VIEW |") == .createView)
        #expect(clause("CREATE VIEW v |") == .createView)
        #expect(clause("CREATE VIEW v AS |") == .createView)
        // A.7: the view body is a normal query.
        #expect(clause("CREATE VIEW v AS SELECT * FROM |") == .from)
        #expect(clause("CREATE MATERIALIZED VIEW v AS SELECT a FROM t WHERE |", .postgresql) == .whereClause)
    }

    @Test func parenRules() throws {
        #expect(clause("SELECT * FROM a JOIN b USING (|") == .using)
        #expect(clause("SELECT ROW_NUMBER() OVER (|") == .window)
        #expect(clause("SELECT ROW_NUMBER() OVER (PARTITION BY a ORDER BY lower(b), |") == .window)
        #expect(clause("SELECT a FROM t WINDOW w AS (PARTITION BY |") == .window)
        #expect(clause("SELECT * FROM users WHERE id IN (|") == .inList)
        #expect(clause("SELECT * FROM users LIMIT |") == .limit)
        #expect(clause("SELECT * FROM users LIMIT 10 OFFSET |") == .limit)
        // `LIMIT 10 |` falls through to the nearest keyword.
        #expect(clause("SELECT * FROM users ORDER BY name ASC LIMIT 10 OFF|") == .orderBy)
        #expect(clause("INSERT INTO users (name) VALUES ('test') RE|") == .values)
        #expect(clause("INSERT INTO users (name) VALUES ('test') |") == .values)
        #expect(clause("INSERT INTO t VALUES (1) RETURNING |") == .returning)
        #expect(clause("INSERT INTO t VALUES (|") == .values)
        #expect(clause("INSERT INTO t VALUES (1), (|") == .values)
        #expect(clause("INSERT INTO t VALUES (lower(|") == .values)
        #expect(clause("INSERT INTO users (id, |") == .insertColumns)
        // A.8: a schema-qualified target is still a column list.
        let qualified = try #require(analyze("INSERT INTO app.users (|"))
        #expect(qualified.clause == .insertColumns && qualified.targetTable == SQLTableReference(schema: "app", table: "users"))
    }

    @Test func structuralRulesBeatFunctionArguments() {
        #expect(clause("CREATE TABLE test (id |") == .createTable)
        #expect(clause("SELECT COUNT(|") == .selectList)
        #expect(clause("COUNT(|") == .functionArgument)
        #expect(analyze("COUNT(|")?.currentFunction == "COUNT")
    }

    // MARK: Nearest keyword (2.4 step 3)

    @Test func nearestKeyword() throws {
        #expect(clause("SELECT |") == .selectList)
        #expect(clause("SELECT|") == .unknown)
        let from = try #require(analyze("SELECT * FROM |"))
        #expect(from.clause == .from && from.expectsObjectName)
        let named = try #require(analyze("SELECT * FROM users |"))
        #expect(named.clause == .from && !named.expectsObjectName)
        #expect(try #require(analyze("SELECT * FROM a, |")).expectsObjectName)
        #expect(try #require(analyze("SELECT * FROM a, b |")).expectsObjectName == false)
        let join = try #require(analyze("SELECT * FROM users JOIN |"))
        #expect(join.clause == .join && join.expectsObjectName)
        let rejoin = "SELECT * FROM happiness_scores hs INNER JOIN country_stats cs ON hs.country = cs.country INNER JOIN |"
        #expect(try #require(analyze(rejoin)).clause == .join)
        #expect(clause("SELECT * FROM a JOIN b ON a.id = b.id INNE|") == .on)
        #expect(clause("SELECT * FROM users WHERE |") == .whereClause)
        #expect(clause("SELECT * FROM users WHERE id = 1 AND |") == .and)
        #expect(clause("SELECT * FROM users WHERE a = 1 OR |") == .and)
        #expect(clause("SELECT COUNT(*) FROM users GROUP BY status |") == .groupBy)
        #expect(clause("SELECT * FROM users ORDER BY name |") == .orderBy)
        #expect(clause("SELECT a FROM t GROUP BY a HAVING |") == .having)
        #expect(clause("UPDATE users SET |") == .set)
        #expect(clause("UPDATE users SET name = 'a' WHERE |") == .whereClause)
        let into = try #require(analyze("INSERT INTO |"))
        #expect(into.clause == .into && into.expectsObjectName)
        #expect(try #require(analyze("INSERT INTO users |")).expectsObjectName == false)
        #expect(clause("SELECT id FROM users UNION |") == .union)
        #expect(clause("DELETE FROM users WHERE |") == .whereClause)
        #expect(clause("randomword |") == .unknown)
        #expect(clause("|") == .unknown)
    }

    @Test func stringsAndQuotedNamesNeverCountAsKeywords() {
        #expect(clause("SELECT * FROM users WHERE name = 'FROM JOIN' AND |") == .and)
        #expect(clause("SELECT * FROM t WHERE `order` = |") == .whereClause)
        #expect(clause("SELECT * FROM t /* FROM */ WHERE |") == .whereClause)
    }

    @Test func caseBlocks() {
        #expect(clause("SELECT CASE WHEN a THEN b END, |") == .selectList)
        #expect(clause("SELECT CASE WHEN x = 1 THEN |") == .caseExpression)
        #expect(clause("SELECT CASE |") == .caseExpression)
        #expect(clause("SELECT COALESCE(CASE WHEN a THEN b END, |") == .selectList)
    }

    @Test func subqueryScoping() throws {
        let inner = try #require(analyze("SELECT * FROM t WHERE id IN (SELECT id FROM u WHERE |"))
        #expect(inner.clause == .whereClause && inner.nestingLevel == 1)
        #expect(Set(inner.references.map(\.table)) == ["t", "u"])
        let after = try #require(analyze("SELECT * FROM users WHERE id IN (SELECT 1) AND |"))
        #expect(after.clause == .and && after.nestingLevel == 0)
        #expect(clause("SELECT * FROM (SELECT a FROM |") == .from)
    }

    // MARK: Other facts

    @Test func currentFunctionAndComparison() throws {
        #expect(analyze("SELECT UPPER(LOWER(|")?.currentFunction == "LOWER")
        // A.12: a grouping paren after a comma is not a call of the previous word.
        #expect(analyze("SELECT a, (|")?.currentFunction == nil)
        #expect(analyze("SELECT * FROM t WHERE x IN (|")?.currentFunction == nil)
        #expect(analyze("SELECT * FROM users WHERE status = |")?.comparisonColumn == "status")
        #expect(analyze("SELECT * FROM users WHERE status = a|")?.comparisonColumn == "status")
        #expect(analyze("SELECT * FROM users u WHERE u.status <> |")?.comparisonColumn == "status")
        #expect(analyze("SELECT * FROM users WHERE status NOT IN |")?.comparisonColumn == "status")
        #expect(analyze("SELECT * FROM users WHERE name LIKE |")?.comparisonColumn == "name")
        #expect(analyze("SELECT * FROM users WHERE |")?.comparisonColumn == nil)
        #expect(analyze("SELECT * FROM users WHERE a = 1 AND = |")?.comparisonColumn == nil)
    }

    // MARK: Table references (3.1–3.2)

    @Test func referencesAndAliases() throws {
        let context = try #require(analyze("SELECT * FROM users u, orders AS o JOIN items i ON i.id = o.id WHERE |"))
        #expect(context.references == [
            SQLTableReference(table: "users", alias: "u"),
            SQLTableReference(table: "orders", alias: "o"),
            SQLTableReference(table: "items", alias: "i"),
        ])
        #expect(try #require(analyze("SELECT | FROM users")).references.map(\.table) == ["users"])
        #expect(try #require(analyze("SELECT * FROM public.users WHERE |", .postgresql)).references == [SQLTableReference(schema: "public", table: "users")])
        #expect(try #require(analyze("SELECT * FROM analytics.sales.orders|")).references.isEmpty)
        #expect(try #require(analyze("SELECT * FROM analytics.sales.orders |")).references == [SQLTableReference(schema: "sales", table: "orders")])
        #expect(try #require(analyze("SELECT * FROM `my db`.`order` |")).references == [SQLTableReference(schema: "my db", table: "order")])
        // Reserved in some engine is not a reason to drop a table name.
        #expect(try #require(analyze("SELECT * FROM user u WHERE |")).references == [SQLTableReference(table: "user", alias: "u")])
        #expect(try #require(analyze("SELECT * FROM sales.|WHERE x")).references.isEmpty)
    }

    @Test func reservedWordsAreNeverAliases() throws {
        // A.4: clause words after a table are not aliases.
        #expect(try #require(analyze("UPDATE users SET |")).references == [SQLTableReference(table: "users")])
        #expect(try #require(analyze("SELECT * FROM a JOIN t USING (|")).references == [SQLTableReference(table: "a"), SQLTableReference(table: "t")])
        #expect(try #require(analyze("SELECT * FROM t LIMIT |")).references == [SQLTableReference(table: "t")])
        #expect(try #require(analyze("SELECT * FROM t WINDOW w AS (|")).references == [SQLTableReference(table: "t")])
    }

    @Test func dmlAndDdlTargets() throws {
        let update = try #require(analyze("UPDATE users u SET name = 'x' WHERE |"))
        #expect(update.references == [SQLTableReference(table: "users", alias: "u")])
        #expect(update.targetTable == SQLTableReference(table: "users", alias: "u"))
        #expect(try #require(analyze("INSERT INTO users (id, |")).targetTable == SQLTableReference(table: "users"))
        #expect(try #require(analyze("DELETE FROM users WHERE |")).references == [SQLTableReference(table: "users")])
        #expect(try #require(analyze("ALTER TABLE users DROP COLUMN |")).references == [SQLTableReference(table: "users")])
        #expect(try #require(analyze("INSERT INTO t (a) VALUES (1) ON DUPLICATE KEY UPDATE a = |")).references == [SQLTableReference(table: "t")])
    }

    @Test func functionFromIsNotATable() throws {
        let context = try #require(analyze("SELECT EXTRACT(YEAR FROM created_at), TRIM(BOTH 'x' FROM name) FROM users WHERE |"))
        #expect(context.references == [SQLTableReference(table: "users")])
    }

    @Test func derivedTablesAndCTEs() throws {
        let derived = try #require(analyze("SELECT ahs.| FROM happiness_scores hs LEFT JOIN (SELECT country, AVG(score) AS avg_score FROM happiness_scores GROUP BY country) ahs ON hs.country = ahs.country"))
        let ahs = try #require(derived.references.first { $0.identifier == "ahs" })
        #expect(ahs.derivedColumns == ["country", "avg_score"])

        let cte = try #require(analyze("WITH totals AS (SELECT region, SUM(amount) AS total FROM sales GROUP BY region) SELECT t.| FROM totals t"))
        #expect(cte.cteNames == ["totals"])
        let totals = try #require(cte.references.first { $0.identifier == "t" })
        #expect(totals.derivedColumns == ["region", "total"])
        #expect(cte.references.contains { $0.table == "sales" })

        let explicit = try #require(analyze("WITH totals (region, amount) AS (SELECT country, SUM(score) FROM s GROUP BY country) SELECT * FROM totals|"))
        #expect(explicit.references.first { $0.table == "totals" }?.derivedColumns == ["region", "amount"])

        let star = try #require(analyze("SELECT * FROM (SELECT * FROM users) d WHERE d.|"))
        #expect(star.references.first { $0.identifier == "d" }?.derivedColumns == [])
        #expect(star.references.contains { $0.table == "users" })
    }

    @Test func outputColumnNames() throws {
        func columns(_ select: String) -> [String] {
            let t = SQLScanTokens(SQLLexer.tokenize(select, family: .postgresql))
            return SQLTableExtractor.outputColumns(t, from: 0, to: t.count)
        }
        #expect(columns("SELECT country, AVG(score) AS avg_score FROM x") == ["country", "avg_score"])
        #expect(columns("SELECT u.*, u.id FROM users u") == ["id"])
        #expect(columns("SELECT name, COUNT(*) FROM t") == ["name"])
        #expect(columns("SELECT COALESCE(a, b) AS first_set, c") == ["first_set", "c"])
        #expect(columns("SELECT DISTINCT ON (a) a, b, B FROM t") == ["a", "b"])
        #expect(columns("SELECT count(*) n, x::int, \"Mixed\" FROM t") == ["n", "Mixed"])
    }

    @Test func subqueriesInSelectListAreNotDerivedTables() throws {
        let context = try #require(analyze("SELECT a, (SELECT max(x) FROM y) AS m FROM t WHERE |"))
        #expect(!context.references.contains { $0.identifier == "m" })
        let fromComma = try #require(analyze("SELECT * FROM t, (SELECT a FROM y) d WHERE |"))
        #expect(fromComma.references.first { $0.identifier == "d" }?.derivedColumns == ["a"])
    }

    // MARK: Literals, quoting and lexing agree (review fixes)

    @Test func quoteTypedBeforeExistingTextKeepsLaterTables() throws {
        // A quote typed in front of existing text names only what precedes the caret (spec 3.4, A.1, A.2).
        let pg = try #require(analyze("SELECT u.\"na| FROM users u", .postgresql))
        #expect(pg.qualifier == "u" && pg.token == "\"na" && pg.prefix == "na")
        #expect(pg.references == [SQLTableReference(table: "users", alias: "u")])
        let backtick = try #require(analyze("SELECT u.`na| FROM users u"))
        #expect(backtick.references == [SQLTableReference(table: "users", alias: "u")])
        let joined = try #require(analyze("SELECT `na| FROM users u JOIN orders o ON o.user_id = u.id"))
        #expect(joined.references == [SQLTableReference(table: "users", alias: "u"), SQLTableReference(table: "orders", alias: "o")])
        #expect(try #require(analyze("SELECT \"| FROM users", .postgresql)).references == [SQLTableReference(table: "users")])
        // The statement still ends at the next `;`.
        let text = "SELECT \"na FROM users; SELECT 2"
        let split = try #require(SQLContextAnalyzer.analyze(text: text, caret: 10, family: .postgresql))
        #expect(split.statementRange == NSRange(location: 0, length: 22))
    }

    @Test func editingAnExistingQuotedNameKeepsIt() throws {
        let inside = try #require(analyze("SELECT \"na|me\" FROM users", .postgresql))
        #expect(inside.token == "\"na" && inside.references == [SQLTableReference(table: "users")])
        let paired = try #require(analyze("SELECT u.\"na|\" FROM users u", .postgresql))
        #expect(paired.prefix == "na" && paired.references == [SQLTableReference(table: "users", alias: "u")])
    }

    @Test func unterminatedQuotedNameEndsAtTheLineBreak() throws {
        let context = try #require(analyze("SELECT \"a, b\nFROM users WHERE c|", .postgresql))
        #expect(context.token == "c" && context.replacementRange.length == 1)
        #expect(context.clause == .whereClause && context.references == [SQLTableReference(table: "users")])
        let mysql = try #require(analyze("SELECT `a, b\nFROM users WHERE c|"))
        #expect(mysql.token == "c" && mysql.clause == .whereClause)
    }

    @Test func escapeStringsAndDollarsInNames() throws {
        // PostgreSQL E'…' honors backslash escapes; plain '…' does not.
        #expect(clause("SELECT * FROM users WHERE name = E'it\\'s' AND |", .postgresql) == .and)
        #expect(analyze("SELECT * FROM users WHERE name = E'it\\'s |", .postgresql) == nil)
        #expect(clause("SELECT * FROM users WHERE name = 'it\\' AND |", .postgresql) == .and)
        #expect(analyze("SELECT * FROM users WHERE name = 'it\\' AND |", .mysql) == nil)
        // `$` inside a name does not open a dollar-quoted body.
        let dollar = try #require(analyze("SELECT a$b$ FROM users WHERE |", .postgresql))
        #expect(dollar.clause == .whereClause && dollar.references == [SQLTableReference(table: "users")])
        #expect(analyze("SELECT $tag$ body |", .postgresql) == nil)
    }

    @Test func unknownDialectSplitsStatementsLikeItsScan() throws {
        // Without a dialect, '…' honors backslash escapes in the scan and in statement splitting alike.
        let context = try #require(analyze("SELECT 'it\\'s' FROM t; SELECT * FROM |", nil))
        #expect(context.clause == .from && context.statementRange.location == 22)
    }

    @Test func nestedCommentsHideTheirText() throws {
        let context = try #require(analyze("/* a /* b */ FROM ghost */ SELECT * FROM users WHERE |", .postgresql))
        #expect(context.references == [SQLTableReference(table: "users")])
    }

    @Test func sqliteBracketNames() throws {
        let context = try #require(analyze("SELECT o.| FROM [order items] o", .sqlite))
        #expect(context.references == [SQLTableReference(table: "order items", alias: "o")])
        // A quote inside brackets opens no string.
        let quote = try #require(analyze("SELECT [it's] FROM t WHERE |", .sqlite))
        #expect(quote.clause == .whereClause && quote.references == [SQLTableReference(table: "t")])
    }

    @Test func engineReservedWordsAreNeverAliases() throws {
        // DuckDB clause words after a table (A.4).
        let asof = try #require(analyze("SELECT * FROM users ASOF JOIN orders o ON |", .duckdb))
        #expect(asof.references == [SQLTableReference(table: "users"), SQLTableReference(table: "orders", alias: "o")])
        #expect(try #require(analyze("SELECT * FROM users QUALIFY |", .duckdb)).references == [SQLTableReference(table: "users")])
        #expect(try #require(analyze("SELECT * FROM users POSITIONAL JOIN orders WHERE |", .duckdb)).references.first == SQLTableReference(table: "users"))
        // `rank` is reserved in MySQL 8 but an ordinary alias in PostgreSQL.
        #expect(try #require(analyze("SELECT * FROM users rank WHERE |", .mysql)).references == [SQLTableReference(table: "users")])
        #expect(try #require(analyze("SELECT * FROM users rank WHERE |", .postgresql)).references == [SQLTableReference(table: "users", alias: "rank")])
        #expect(try #require(analyze("SELECT * FROM users verbose WHERE |", .postgresql)).references == [SQLTableReference(table: "users")])
    }

    @Test func fromListGoesOnAfterADerivedTable() throws {
        let context = try #require(analyze("SELECT * FROM (SELECT id FROM users) d, orders o WHERE |"))
        #expect(context.references.contains(SQLTableReference(table: "orders", alias: "o")))
        #expect(context.references.first { $0.identifier == "d" }?.derivedColumns == ["id"])
        // Commas inside the derived table split nothing.
        let inner = try #require(analyze("SELECT * FROM (SELECT a, b FROM x) d, orders o WHERE |"))
        #expect(Set(inner.references.map(\.identifier)) == ["x", "d", "o"])
        let function = try #require(analyze("SELECT * FROM generate_series(1, 3) g, users u WHERE |", .postgresql))
        #expect(function.references.contains(SQLTableReference(table: "users", alias: "u")))
    }

    @Test func lateralDerivedTables() throws {
        let context = try #require(analyze("SELECT * FROM users u, LATERAL (SELECT o.total FROM orders o WHERE o.user_id = u.id) x WHERE x.|", .postgresql))
        #expect(context.references.first { $0.identifier == "x" }?.derivedColumns == ["total"])
        let join = try #require(analyze("SELECT y.| FROM users u JOIN LATERAL (SELECT 1 AS one) y ON true", .postgresql))
        #expect(join.references.first { $0.identifier == "y" }?.derivedColumns == ["one"])
    }

    @Test func literalsAreNotOutputColumns() throws {
        let context = try #require(analyze("SELECT d.| FROM (SELECT 'hello', id FROM users) d"))
        #expect(context.references.first { $0.identifier == "d" }?.derivedColumns == ["id"])
        func columns(_ select: String) -> [String] {
            let t = SQLScanTokens(SQLLexer.tokenize(select, family: .postgresql))
            return SQLTableExtractor.outputColumns(t, from: 0, to: t.count)
        }
        #expect(columns("SELECT 'hello' AS greeting, 'x' y, NULL, CURRENT_DATE FROM t") == ["greeting", "y"])
        #expect(columns("SELECT CASE WHEN a THEN 1 END n FROM t") == ["n"])
        let cte = try #require(analyze("WITH c ('a', b) AS (SELECT 1, 2) SELECT * FROM c|"))
        #expect(cte.references.first { $0.table == "c" }?.derivedColumns == ["b"])
    }

    @Test func alterColumnNamesAColumn() {
        #expect(clause("ALTER TABLE users ALTER COLUMN |", .postgresql) == .alterTableColumn)
        #expect(clause("ALTER TABLE users ALTER |", .postgresql) == .alterTableColumn)
    }
}
