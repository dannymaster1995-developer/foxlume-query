import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Scratch table names for live structure tests. Every test creates and drops its own `fq_struct_` tables.
private func scratchName(_ label: String) -> String {
    "fq_struct_\(label)_" + UUID().uuidString.prefix(8).lowercased()
}

private func scalar(_ connection: DatabaseConnection, _ sql: String) throws -> String? {
    try connection.execute(sql, rowLimit: nil).last { $0.hasResultSet }?.rows.first?.first?.textValue
}

@Suite("Structure editing on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresStructureLiveTests {
    let generator = TableDDLGenerator(dialect: .postgresql)

    @Test func createTableThenEditEveryKindOfObject() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let parentName = scratchName("parent")
        let childName = scratchName("child")
        let parent = TableRef(schema: "public", name: parentName)
        let child = TableRef(schema: "public", name: childName)
        defer {
            _ = try? connection.execute("DROP TABLE IF EXISTS \(SQLDialect.postgresql.qualifiedName(child)), \(SQLDialect.postgresql.qualifiedName(parent))", rowLimit: nil)
        }

        var parentDraft = StructureDraft(newTable: parent)
        parentDraft.addColumn(ColumnDefinition(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true, isAutoIncrement: true))
        parentDraft.addColumn(ColumnDefinition(name: "code", dataType: "text", isNullable: false))
        parentDraft.addIndex(IndexDefinition(name: "\(parentName)_code_key", columns: ["code"], isUnique: true))
        try connection.applySchemaStatements(try generator.createStatements(parentDraft), transactional: true)

        var draft = StructureDraft(newTable: child)
        draft.comment = "scratch child"
        draft.addColumn(ColumnDefinition(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, isAutoIncrement: true))
        draft.addColumn(ColumnDefinition(name: "email", dataType: "varchar(100)", isNullable: false, comment: "login"))
        draft.addColumn(ColumnDefinition(name: "status", dataType: "text", isNullable: false, defaultValue: "'new'"))
        draft.addColumn(ColumnDefinition(name: "parent_id", dataType: "integer"))
        draft.addColumn(ColumnDefinition(name: "", dataType: ""))
        draft.addIndex(IndexDefinition(name: "\(childName)_email_key", columns: ["email"], isUnique: true))
        draft.addForeignKey(ForeignKeyDefinition(name: "\(childName)_parent_fk", columns: ["parent_id"], referencedTable: parent, referencedColumns: ["id"], onDelete: .cascade))
        try connection.applySchemaStatements(try generator.createStatements(draft), transactional: true)

        var structure = try connection.structure(of: child)
        #expect(structure.columns.map(\.name) == ["id", "email", "status", "parent_id"])
        #expect(structure.primaryKey == ["id"])
        #expect(structure.columns[0].isAutoIncrement)
        #expect(structure.columns[1].comment == "login")
        #expect(structure.columns[2].defaultValue == "'new'::text")
        #expect(structure.comment == "scratch child")
        #expect(structure.indexes.contains { $0.name == "\(childName)_email_key" && $0.isUnique })
        #expect(structure.foreignKeys.first?.onDelete == "CASCADE")

        // Rename, retype, default, nullability, comment; add and drop columns; key, index, foreign key and comment changes.
        var edit = StructureDraft(structure: structure, family: .postgresql)
        edit.updateColumn(at: 1) { $0.name = "mail"; $0.dataType = "varchar(200)"; $0.comment = "" }
        edit.updateColumn(at: 2) { $0.defaultValue = "'open'"; $0.isNullable = true }
        edit.toggleDeletion(.columns, rows: IndexSet(integer: 3))
        let added = edit.addColumn(ColumnDefinition(name: "region", dataType: "char(2)", isNullable: false, defaultValue: "'EU'", comment: "two letters"))
        edit.updateColumn(at: added) { $0.isPrimaryKey = true }
        edit.addIndex(IndexDefinition(name: "\(childName)_status_lower", columns: ["lower(status)"]))
        edit.toggleDeletion(.foreignKeys, rows: IndexSet(integer: 0))
        edit.comment = "edited"
        let statements = try generator.alterStatements(edit)
        try connection.applySchemaStatements(statements, transactional: true)

        structure = try connection.structure(of: child)
        #expect(structure.columns.map(\.name) == ["id", "mail", "status", "region"])
        #expect(structure.columns[1].dataType == "character varying(200)")
        #expect(structure.columns[1].comment == nil)
        #expect(structure.columns[2].defaultValue == "'open'::text")
        #expect(structure.columns[2].isNullable)
        #expect(structure.columns[3].comment == "two letters")
        #expect(structure.primaryKey == ["id", "region"])
        #expect(structure.indexes.first { $0.name == "\(childName)_email_key" }?.columns == ["mail"])
        #expect(structure.indexes.contains { $0.name == "\(childName)_status_lower" })
        #expect(structure.foreignKeys.isEmpty)
        #expect(structure.comment == "edited")

        // The edited structure loads as a draft with nothing pending.
        #expect(!StructureDraft(structure: structure, family: .postgresql).hasChanges)
    }

    @Test func autoIncrementCanBeSwitchedOnAndOffForAFilledColumn() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let table = TableRef(schema: "public", name: scratchName("auto"))
        let name = SQLDialect.postgresql.qualifiedName(table)
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(name)", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE \(name) (n integer, label text); INSERT INTO \(name) VALUES (1, 'a'), (7, 'b')", rowLimit: nil)

        var draft = StructureDraft(structure: try connection.structure(of: table), family: .postgresql)
        draft.updateColumn(at: 0) { $0.isAutoIncrement = true }
        try connection.applySchemaStatements(try generator.alterStatements(draft), transactional: true)
        var structure = try connection.structure(of: table)
        #expect(structure.columns[0].isAutoIncrement)
        #expect(!structure.columns[0].isNullable)
        // The identity continues after the rows already there.
        _ = try connection.execute("INSERT INTO \(name) (label) VALUES ('c')", rowLimit: nil)
        #expect(try scalar(connection, "SELECT n FROM \(name) WHERE label = 'c'") == "8")

        draft = StructureDraft(structure: structure, family: .postgresql)
        draft.updateColumn(at: 0) { $0.isAutoIncrement = false }
        try connection.applySchemaStatements(try generator.alterStatements(draft), transactional: true)
        structure = try connection.structure(of: table)
        #expect(!structure.columns[0].isAutoIncrement)
    }

    @Test func typeChangesKeepANonDefaultCollation() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let table = TableRef(schema: "public", name: scratchName("coll"))
        let name = SQLDialect.postgresql.qualifiedName(table)
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(name)", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE \(name) (code varchar(10) COLLATE \"C\", plain text)", rowLimit: nil)

        var structure = try connection.structure(of: table)
        #expect(structure.columns[0].collation == "C")
        #expect(structure.columns[1].collation == nil)
        var draft = StructureDraft(structure: structure, family: .postgresql)
        draft.updateColumn(at: 0) { $0.dataType = "varchar(40)" }
        try connection.applySchemaStatements(try generator.alterStatements(draft), transactional: true)
        structure = try connection.structure(of: table)
        #expect(structure.columns[0].dataType == "character varying(40)")
        #expect(structure.columns[0].collation == "C")
    }

    @Test func aFailingScriptIsRolledBack() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let table = TableRef(schema: "public", name: scratchName("fail"))
        let name = SQLDialect.postgresql.qualifiedName(table)
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(name)", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE \(name) (a integer, b text); INSERT INTO \(name) VALUES (1, NULL)", rowLimit: nil)

        var draft = StructureDraft(structure: try connection.structure(of: table), family: .postgresql)
        draft.updateColumn(at: 0) { $0.dataType = "bigint" }
        draft.updateColumn(at: 1) { $0.isNullable = false }
        draft.addColumn(ColumnDefinition(name: "c", dataType: "integer"))
        let statements = try generator.alterStatements(draft)
        #expect(statements.count == 3)
        let error = #expect(throws: SchemaScriptError.self) {
            try connection.applySchemaStatements(statements, transactional: true)
        }
        #expect(error?.position == 2)
        #expect(error?.rolledBack == true)
        // The type change before the failure was undone too, and the session is usable again.
        let columns = try connection.structure(of: table).columns
        #expect(columns.map(\.name) == ["a", "b"])
        #expect(columns.first?.dataType == "integer")
    }
}

@Suite("Structure editing on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLStructureLiveTests {
    let generator = TableDDLGenerator(dialect: .mysql)

    @Test func createTableThenEditEveryKindOfObject() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        let parentName = scratchName("parent")
        let childName = scratchName("child")
        let parent = TableRef(name: parentName)
        let child = TableRef(name: childName)
        defer {
            _ = try? connection.execute("DROP TABLE IF EXISTS `\(childName)`", rowLimit: nil)
            _ = try? connection.execute("DROP TABLE IF EXISTS `\(parentName)`", rowLimit: nil)
        }

        var parentDraft = StructureDraft(newTable: parent)
        parentDraft.addColumn(ColumnDefinition(name: "id", dataType: "int", isNullable: false, isAutoIncrement: true))
        try connection.applySchemaStatements(try generator.createStatements(parentDraft, options: .mysqlDefaults), transactional: false)
        #expect(try connection.structure(of: parent).primaryKey == ["id"], "an auto increment column becomes the key")

        var draft = StructureDraft(newTable: child)
        draft.comment = "scratch child"
        draft.addColumn(ColumnDefinition(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true, isAutoIncrement: true))
        draft.addColumn(ColumnDefinition(name: "email", dataType: "varchar(100)", isNullable: false, defaultValue: "''", comment: "login"))
        draft.addColumn(ColumnDefinition(name: "touched", dataType: "timestamp", defaultValue: "CURRENT_TIMESTAMP"))
        draft.addColumn(ColumnDefinition(name: "token", dataType: "char(36)", defaultValue: "uuid()"))
        draft.addColumn(ColumnDefinition(name: "parent_id", dataType: "int"))
        draft.addIndex(IndexDefinition(name: "email_uq", columns: ["email"], isUnique: true))
        draft.addForeignKey(ForeignKeyDefinition(name: "\(childName)_fk", columns: ["parent_id"], referencedTable: parent, referencedColumns: ["id"], onDelete: .setNull))
        try connection.applySchemaStatements(try generator.createStatements(draft, options: .mysqlDefaults), transactional: false)

        var structure = try connection.structure(of: child)
        #expect(structure.columns.map(\.name) == ["id", "email", "touched", "token", "parent_id"])
        #expect(structure.primaryKey == ["id"])
        #expect(structure.columns[0].isAutoIncrement)
        #expect(structure.columns[1].comment == "login")
        #expect(structure.comment == "scratch child")
        #expect(structure.indexes.contains { $0.name == "email_uq" && $0.isUnique })
        #expect(structure.foreignKeys.first?.onDelete == "SET NULL")
        var loaded = StructureDraft(structure: structure, family: .mysql)
        #expect(loaded.columns[1].current.defaultValue == "''")
        #expect(loaded.columns[3].current.defaultValue == "(uuid())")
        #expect(!loaded.hasChanges)

        // Rename keeps the rest of the definition; ON UPDATE survives a comment change.
        loaded.updateColumn(at: 1) { $0.name = "mail"; $0.dataType = "varchar(150)" }
        loaded.updateColumn(at: 2) { $0.comment = "changed" }
        loaded.toggleDeletion(.columns, rows: IndexSet(integer: 3))
        loaded.addColumn(ColumnDefinition(name: "score", dataType: "decimal(5,2)", isNullable: false, defaultValue: "0"))
        loaded.addIndex(IndexDefinition(name: "mail_prefix", columns: ["mail(10)"]))
        loaded.updateForeignKey(at: 0) { $0.onDelete = .cascade }
        loaded.comment = ""
        try connection.applySchemaStatements(try generator.alterStatements(loaded), transactional: false)

        structure = try connection.structure(of: child)
        #expect(structure.columns.map(\.name) == ["id", "mail", "touched", "parent_id", "score"])
        #expect(structure.columns[1].dataType == "varchar(150)")
        #expect(structure.columns[1].comment == "login")
        #expect(structure.columns[1].defaultValue == "")
        #expect(structure.columns[2].comment == "changed")
        #expect(structure.columns[4].defaultValue == "0.00")
        #expect(structure.indexes.first { $0.name == "email_uq" }?.columns == ["mail"])
        #expect(structure.indexes.contains { $0.name == "mail_prefix" })
        #expect(structure.foreignKeys.first?.onDelete == "CASCADE")
        #expect(structure.comment == nil)
        #expect(!StructureDraft(structure: structure, family: .mysql).hasChanges)
    }

    @Test func movingThePrimaryKeyToANewAutoIncrementColumn() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        let table = TableRef(name: scratchName("pk"))
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS `\(table.name)`", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE `\(table.name)` (id int NOT NULL AUTO_INCREMENT PRIMARY KEY, label varchar(10)); INSERT INTO `\(table.name)` (label) VALUES ('a'), ('b')", rowLimit: nil)

        var draft = StructureDraft(structure: try connection.structure(of: table), family: .mysql)
        draft.updateColumn(at: 0) { $0.isPrimaryKey = false; $0.isAutoIncrement = false }
        let uid = draft.addColumn(ColumnDefinition(name: "uid", dataType: "bigint", isNullable: false))
        draft.updateColumn(at: uid) { $0.isPrimaryKey = true; $0.isAutoIncrement = true }
        let statements = try generator.alterStatements(draft)
        #expect(statements.count == 1)
        try connection.applySchemaStatements(statements, transactional: false)

        let structure = try connection.structure(of: table)
        #expect(structure.primaryKey == ["uid"])
        #expect(structure.columns.first { $0.name == "uid" }?.isAutoIncrement == true)
        #expect(structure.columns.first { $0.name == "id" }?.isAutoIncrement == false)
        #expect(try scalar(connection, "SELECT COUNT(DISTINCT uid) FROM `\(table.name)`") == "2")
    }

    @Test func collationAndGeneratedColumnsSurviveRedefinition() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        let table = TableRef(name: scratchName("keep"))
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS `\(table.name)`", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE `\(table.name)` (b int, code varchar(10) COLLATE utf8mb4_bin, m int GENERATED ALWAYS AS (b + 1) VIRTUAL)", rowLimit: nil)

        var structure = try connection.structure(of: table)
        #expect(structure.columns[1].collation == "utf8mb4_bin")
        #expect(structure.columns[0].collation == nil)
        var draft = StructureDraft(structure: structure, family: .mysql)
        draft.updateColumn(at: 1) { $0.dataType = "varchar(20)" }
        draft.updateColumn(at: 2) { $0.comment = "derived" }
        try connection.applySchemaStatements(try generator.alterStatements(draft), transactional: false)

        structure = try connection.structure(of: table)
        #expect(structure.columns[1].dataType == "varchar(20)")
        #expect(structure.columns[1].collation == "utf8mb4_bin")
        #expect(structure.columns[2].comment == "derived")
        #expect(structure.columns[2].generationExpression != nil)
    }

    @Test func aFailingStatementStopsTheScriptAndEarlierOnesStay() throws {
        let connection = try MySQLTestServer.connect(ssl: .disable)
        defer { connection.close() }
        let table = TableRef(name: scratchName("fail"))
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS `\(table.name)`", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE `\(table.name)` (a int, b varchar(10)); INSERT INTO `\(table.name)` VALUES (1, 'x'), (1, 'y')", rowLimit: nil)

        var draft = StructureDraft(structure: try connection.structure(of: table), family: .mysql)
        draft.addColumn(ColumnDefinition(name: "c", dataType: "int"))
        draft.addIndex(IndexDefinition(name: "a_unique", columns: ["a"], isUnique: true))
        let statements = try generator.alterStatements(draft)
        #expect(statements.count == 2)
        let error = #expect(throws: SchemaScriptError.self) {
            try connection.applySchemaStatements(statements, transactional: false)
        }
        #expect(error?.position == 2)
        #expect(error?.rolledBack == false)
        #expect(try connection.structure(of: table).columns.map(\.name) == ["a", "b", "c"])
    }
}
