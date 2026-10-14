import Foundation
import Testing
@testable import FoxlumeQueryCore

/// A small `orders` table as the PostgreSQL driver reports it.
private func postgresOrders() -> TableStructure {
    TableStructure(
        table: TableRef(schema: "public", name: "orders"),
        columns: [
            ColumnInfo(name: "id", dataType: "bigint", isNullable: false, defaultValue: "nextval('orders_id_seq'::regclass)", isPrimaryKey: true, isAutoIncrement: true),
            ColumnInfo(name: "user_id", dataType: "integer", isNullable: false),
            ColumnInfo(name: "status", dataType: "text", isNullable: false, defaultValue: "'pending'::text"),
            ColumnInfo(name: "note", dataType: "character varying(20)", comment: "free text", collation: "C"),
        ],
        indexes: [
            IndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true, method: "btree"),
            IndexInfo(name: "orders_status_idx", columns: ["status"], isUnique: false, isPrimary: false, method: "btree"),
            IndexInfo(name: "orders_note_key", columns: ["note"], isUnique: true, isPrimary: false, method: "btree", isConstraint: true),
        ],
        foreignKeys: [
            ForeignKeyInfo(name: "orders_user_id_fkey", columns: ["user_id"], referencedTable: TableRef(schema: "public", name: "users"), referencedColumns: ["id"], onUpdate: "NO ACTION", onDelete: "CASCADE"),
        ],
        comment: "Customer orders"
    )
}

/// The same table as MySQL reports it: literal defaults unquoted, expression defaults flagged in EXTRA.
private func mysqlOrders() -> TableStructure {
    TableStructure(
        table: TableRef(name: "orders"),
        columns: [
            ColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, extra: "auto_increment"),
            ColumnInfo(name: "user_id", dataType: "int", isNullable: false),
            ColumnInfo(name: "status", dataType: "varchar(20)", isNullable: false, defaultValue: "it's"),
            ColumnInfo(name: "touched", dataType: "timestamp", defaultValue: "CURRENT_TIMESTAMP", extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP"),
            ColumnInfo(name: "code", dataType: "varchar(10)", comment: "short", collation: "utf8mb4_bin"),
        ],
        indexes: [
            IndexInfo(name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true, method: "BTREE"),
            IndexInfo(name: "status_idx", columns: ["status"], isUnique: false, isPrimary: false, method: "BTREE"),
        ],
        foreignKeys: [
            ForeignKeyInfo(name: "fk_user", columns: ["user_id"], referencedTable: TableRef(name: "users"), referencedColumns: ["id"], onUpdate: "RESTRICT", onDelete: "CASCADE"),
        ]
    )
}

@Suite struct StructureDraftTests {
    @Test func loadsRowsAndKeepsThePrimaryIndexOutOfTheEditableList() {
        let draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        #expect(draft.columns.count == 4)
        #expect(draft.indexes.map(\.current.name) == ["orders_status_idx", "orders_note_key"])
        #expect(draft.primaryIndex?.name == "orders_pkey")
        #expect(draft.primaryKeyName == "orders_pkey")
        #expect(draft.primaryKey == ["id"])
        #expect(draft.comment == "Customer orders")
        #expect(!draft.hasChanges)
    }

    @Test func editingBackToTheOriginalClearsTheChange() {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 2) { $0.dataType = "varchar(30)" }
        #expect(draft.state(.columns, row: 2) == .modified)
        #expect(draft.changeCount == 1)
        draft.updateColumn(at: 2) { $0.dataType = "text" }
        #expect(draft.state(.columns, row: 2) == .unchanged)
        #expect(!draft.hasChanges)
    }

    @Test func deletingANewRowRemovesItAndDeletingAgainRestores() {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.addColumn(ColumnDefinition(name: "extra", dataType: "text"))
        #expect(draft.state(.columns, row: 4) == .inserted)
        draft.toggleDeletion(.columns, rows: IndexSet([1, 4]))
        #expect(draft.columns.count == 4)
        #expect(draft.state(.columns, row: 1) == .deleted)
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 1))
        #expect(draft.state(.columns, row: 1) == .unchanged)
        #expect(!draft.hasChanges)
    }

    @Test func linkedFieldsFollowPrimaryKeyAndAutoIncrement() {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 3) { $0.isPrimaryKey = true }
        #expect(draft.columns[3].current.isNullable == false)
        draft.updateColumn(at: 3) { $0.isNullable = true }
        #expect(draft.columns[3].current.isNullable == false, "a key column stays NOT NULL")

        let index = draft.addColumn(ColumnDefinition(name: "n", dataType: "integer", isNullable: true, defaultValue: "5"))
        draft.updateColumn(at: index) { $0.isAutoIncrement = true }
        #expect(draft.columns[index].current.isNullable == false)
        #expect(draft.columns[index].current.defaultValue == nil)

        // Turning auto increment off on a serial column takes its sequence default with it.
        draft.updateColumn(at: 0) { $0.isAutoIncrement = false }
        #expect(draft.columns[0].current.defaultValue == nil)

        let other = draft.addColumn(ColumnDefinition(name: "m", dataType: "text", isNullable: true, defaultValue: "NULL"))
        draft.updateColumn(at: other) { $0.isNullable = false }
        #expect(draft.columns[other].current.defaultValue == nil)
    }

    @Test func renamesFollowIntoIndexesAndForeignKeysWithoutChangingThem() {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 2) { $0.name = "state" }
        draft.updateColumn(at: 1) { $0.name = "customer_id" }
        #expect(draft.indexes[0].current.columns == ["state"])
        #expect(draft.foreignKeys[0].current.columns == ["customer_id"])
        #expect(draft.state(.indexes, row: 0) == .unchanged)
        #expect(draft.state(.foreignKeys, row: 0) == .unchanged)
        #expect(draft.changeCount == 2)
        draft.revert(.columns, row: 2)
        #expect(draft.indexes[0].current.columns == ["status"])
    }

    @Test func primaryKeyChangesAreTrackedByRowNotByName() {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 0) { $0.name = "order_id" }
        #expect(draft.primaryKey == ["order_id"])
        #expect(!draft.primaryKeyChanged)

        var replaced = StructureDraft(structure: postgresOrders(), family: .postgresql)
        replaced.updateColumn(at: 0) { $0.isPrimaryKey = false; $0.name = "old_id" }
        let index = replaced.addColumn(ColumnDefinition(name: "id", dataType: "uuid"))
        replaced.updateColumn(at: index) { $0.isPrimaryKey = true }
        #expect(replaced.primaryKey == ["id"])
        #expect(replaced.primaryKeyChanged)

        var composite = StructureDraft(structure: postgresOrders(), family: .postgresql)
        composite.updateColumn(at: 1) { $0.isPrimaryKey = true }
        #expect(composite.primaryKey == ["id", "user_id"])
        #expect(composite.primaryKeyChanged)
    }

    @Test func mysqlDefaultsBecomeSQL() {
        let draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        #expect(draft.columns[2].current.defaultValue == "'it''s'")
        #expect(draft.columns[3].current.defaultValue == "CURRENT_TIMESTAMP")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: "5", dataType: "int", extra: nil) == "5")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: "1.50", dataType: "decimal(5,2)", extra: nil) == "1.50")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: "b'1'", dataType: "bit(1)", extra: nil) == "b'1'")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: "", dataType: "varchar(10)", extra: nil) == "''")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: "a\\b", dataType: "varchar(10)", extra: nil) == "'a\\\\b'")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: "CURRENT_TIMESTAMP(3)", dataType: "datetime(3)", extra: "DEFAULT_GENERATED") == "CURRENT_TIMESTAMP(3)")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: "concat(_utf8mb4\\'x\\',_utf8mb4\\'y\\')", dataType: "varchar(50)", extra: "DEFAULT_GENERATED") == "(concat(_utf8mb4'x',_utf8mb4'y'))")
        #expect(ColumnDefaultSQL.mysqlExpression(raw: nil, dataType: "int", extra: nil) == nil)
    }

    @Test func mysqlDefaultClauseWrapsExpressionsOnly() {
        #expect(ColumnDefaultSQL.mysqlDefaultClause("'x'") == "'x'")
        #expect(ColumnDefaultSQL.mysqlDefaultClause("42") == "42")
        #expect(ColumnDefaultSQL.mysqlDefaultClause("NULL") == "NULL")
        #expect(ColumnDefaultSQL.mysqlDefaultClause("CURRENT_TIMESTAMP(6)") == "CURRENT_TIMESTAMP(6)")
        #expect(ColumnDefaultSQL.mysqlDefaultClause("uuid()") == "(uuid())")
        #expect(ColumnDefaultSQL.mysqlDefaultClause("(UUID())") == "(UUID())")
        #expect(ColumnDefaultSQL.mysqlDefaultClause("_utf8mb4'x'") == "_utf8mb4'x'")
        #expect(ColumnDefaultSQL.mysqlDefaultClause("0x1F") == "0x1F")
    }

    @Test func referentialActionsParseCatalogSpellings() {
        #expect(ReferentialAction(catalog: "set null") == .setNull)
        #expect(ReferentialAction(catalog: "NO_ACTION") == .noAction)
        #expect(ReferentialAction(catalog: nil) == .noAction)
        #expect(!ReferentialAction.offered(for: .mysql).contains(.setDefault))
    }
}

@Suite struct PostgresStructureSQLTests {
    let generator = TableDDLGenerator(dialect: .postgresql)

    @Test func columnChangesComeOneStatementEachInOrder() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 3) {
            $0.name = "notes"
            $0.dataType = "varchar(200)"
            $0.defaultValue = "''"
            $0.isNullable = false
            $0.comment = "it's long"
        }
        #expect(try generator.alterStatements(draft) == [
            #"ALTER TABLE "public"."orders" RENAME COLUMN "note" TO "notes""#,
            #"ALTER TABLE "public"."orders" ALTER COLUMN "notes" TYPE varchar(200) COLLATE "C""#,
            #"ALTER TABLE "public"."orders" ALTER COLUMN "notes" SET DEFAULT ''"#,
            #"ALTER TABLE "public"."orders" ALTER COLUMN "notes" SET NOT NULL"#,
            #"COMMENT ON COLUMN "public"."orders"."notes" IS 'it''s long'"#,
        ])
    }

    @Test func clearingDefaultNullAndCommentUseDropForms() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 2) { $0.defaultValue = ""; $0.isNullable = true }
        draft.updateColumn(at: 3) { $0.comment = "" }
        #expect(try generator.alterStatements(draft) == [
            #"ALTER TABLE "public"."orders" ALTER COLUMN "status" DROP DEFAULT"#,
            #"ALTER TABLE "public"."orders" ALTER COLUMN "status" DROP NOT NULL"#,
            #"COMMENT ON COLUMN "public"."orders"."note" IS NULL"#,
        ])
    }

    @Test func addAndDropColumns() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 3))
        draft.addColumn(ColumnDefinition(name: "total", dataType: "numeric(10,2)", isNullable: false, defaultValue: "0", comment: "sum"))
        draft.addColumn(ColumnDefinition(name: "seq", dataType: "bigint", isNullable: false, isAutoIncrement: true))
        draft.addColumn(ColumnDefinition(name: "", dataType: ""))
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 6))
        #expect(try generator.alterStatements(draft) == [
            #"ALTER TABLE "public"."orders" DROP COLUMN "note""#,
            #"ALTER TABLE "public"."orders" ADD COLUMN "total" numeric(10,2) DEFAULT 0 NOT NULL"#,
            #"ALTER TABLE "public"."orders" ADD COLUMN "seq" bigserial"#,
            #"COMMENT ON COLUMN "public"."orders"."total" IS 'sum'"#,
        ])
    }

    @Test func autoIncrementOnAndOffForExistingColumns() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 1) { $0.isAutoIncrement = true }
        draft.updateColumn(at: 0) { $0.isAutoIncrement = false }
        #expect(try generator.alterStatements(draft) == [
            #"ALTER TABLE "public"."orders" ALTER COLUMN "id" DROP DEFAULT"#,
            #"ALTER TABLE "public"."orders" ALTER COLUMN "user_id" ADD GENERATED BY DEFAULT AS IDENTITY"#,
            #"SELECT pg_catalog.setval(pg_catalog.pg_get_serial_sequence('"public"."orders"', 'user_id'), COALESCE(MAX("user_id"), 0) + 1, false) FROM "public"."orders""#,
        ])

        let identity = TableStructure(table: TableRef(schema: "public", name: "t"), columns: [
            ColumnInfo(name: "id", dataType: "integer", isNullable: false, isAutoIncrement: true, extra: "GENERATED BY DEFAULT AS IDENTITY"),
        ])
        var off = StructureDraft(structure: identity, family: .postgresql)
        off.updateColumn(at: 0) { $0.isAutoIncrement = false }
        #expect(try generator.alterStatements(off) == [#"ALTER TABLE "public"."t" ALTER COLUMN "id" DROP IDENTITY IF EXISTS"#])
    }

    @Test func primaryKeyIsDroppedByItsNameAndAddedBack() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateColumn(at: 1) { $0.isPrimaryKey = true }
        #expect(try generator.alterStatements(draft) == [
            #"ALTER TABLE "public"."orders" DROP CONSTRAINT "orders_pkey""#,
            #"ALTER TABLE "public"."orders" ADD PRIMARY KEY ("id", "user_id")"#,
        ])

        var renamed = StructureDraft(structure: postgresOrders(), family: .postgresql)
        renamed.updateColumn(at: 0) { $0.name = "order_id" }
        #expect(try generator.alterStatements(renamed) == [#"ALTER TABLE "public"."orders" RENAME COLUMN "id" TO "order_id""#])

        var none = StructureDraft(structure: postgresOrders(), family: .postgresql)
        none.updateColumn(at: 0) { $0.isPrimaryKey = false }
        #expect(try generator.alterStatements(none) == [#"ALTER TABLE "public"."orders" DROP CONSTRAINT "orders_pkey""#])
    }

    @Test func droppingTheKeyColumnDropsTheConstraintFirst() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 0))
        #expect(try generator.alterStatements(draft) == [
            #"ALTER TABLE "public"."orders" DROP CONSTRAINT "orders_pkey""#,
            #"ALTER TABLE "public"."orders" DROP COLUMN "id""#,
        ])
    }

    @Test func indexesAreDroppedAndCreated() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateIndex(at: 0) { $0.columns = ["status", "user_id"] }
        draft.toggleDeletion(.indexes, rows: IndexSet(integer: 1))
        draft.addIndex(IndexDefinition(name: "orders_lower_note", columns: ["lower(note)"], isUnique: true))
        draft.addIndex(IndexDefinition(name: "orders_note_gin", columns: ["note"], method: "GIN"))
        #expect(try generator.alterStatements(draft) == [
            #"DROP INDEX "public"."orders_status_idx""#,
            #"ALTER TABLE "public"."orders" DROP CONSTRAINT "orders_note_key""#,
            #"CREATE INDEX "orders_status_idx" ON "public"."orders" ("status", "user_id")"#,
            #"CREATE UNIQUE INDEX "orders_lower_note" ON "public"."orders" ((lower(note)))"#,
            #"CREATE INDEX "orders_note_gin" ON "public"."orders" USING gin ("note")"#,
        ])
    }

    @Test func foreignKeysAreReplacedWithTheirActions() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.updateForeignKey(at: 0) { $0.onDelete = .setNull; $0.onUpdate = .cascade }
        draft.addForeignKey(ForeignKeyDefinition(name: "", columns: ["id"], referencedTable: TableRef(schema: "shop", name: "products"), referencedColumns: ["id"]))
        #expect(try generator.alterStatements(draft) == [
            #"ALTER TABLE "public"."orders" DROP CONSTRAINT "orders_user_id_fkey""#,
            #"ALTER TABLE "public"."orders" ADD CONSTRAINT "orders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users" ("id") ON DELETE SET NULL ON UPDATE CASCADE"#,
            #"ALTER TABLE "public"."orders" ADD FOREIGN KEY ("id") REFERENCES "shop"."products" ("id")"#,
        ])
    }

    @Test func tableCommentIsSetOrCleared() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.comment = "All orders"
        #expect(try generator.alterStatements(draft) == [#"COMMENT ON TABLE "public"."orders" IS 'All orders'"#])
        draft.comment = ""
        #expect(try generator.alterStatements(draft) == [#"COMMENT ON TABLE "public"."orders" IS NULL"#])
    }

    @Test func fullScriptFollowsTheDocumentedOrder() throws {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.comment = "changed"
        draft.addForeignKey(ForeignKeyDefinition(name: "fk_new", columns: ["user_id"], referencedTable: TableRef(schema: "public", name: "users"), referencedColumns: ["id"]))
        draft.addIndex(IndexDefinition(name: "idx_new", columns: ["user_id"]))
        draft.addColumn(ColumnDefinition(name: "added", dataType: "text"))
        draft.updateColumn(at: 2) { $0.dataType = "varchar(20)" }
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 3))
        draft.updateColumn(at: 1) { $0.isPrimaryKey = true }
        draft.toggleDeletion(.indexes, rows: IndexSet(integer: 0))
        draft.toggleDeletion(.foreignKeys, rows: IndexSet(integer: 0))
        let statements = try generator.alterStatements(draft)
        let kinds = statements.map { statement -> String in
            if statement.hasPrefix("COMMENT ON TABLE") { return "table comment" }
            if statement.contains("DROP CONSTRAINT \"orders_user_id_fkey\"") { return "drop fk" }
            if statement.hasPrefix("DROP INDEX") { return "drop index" }
            if statement.contains("DROP CONSTRAINT \"orders_pkey\"") { return "drop pk" }
            if statement.contains("DROP COLUMN") { return "drop column" }
            if statement.contains("ALTER COLUMN") { return "modify column" }
            if statement.contains("ADD COLUMN") { return "add column" }
            if statement.contains("ADD PRIMARY KEY") { return "add pk" }
            if statement.hasPrefix("CREATE INDEX") { return "add index" }
            if statement.contains("FOREIGN KEY") { return "add fk" }
            return statement
        }
        #expect(kinds == ["drop fk", "drop index", "drop pk", "drop column", "modify column", "add column", "add pk", "add index", "add fk", "table comment"])
    }

    @Test func problemsAreReportedBeforeAnythingIsGenerated() {
        var draft = StructureDraft(structure: postgresOrders(), family: .postgresql)
        draft.addColumn(ColumnDefinition(name: "", dataType: "text"))
        draft.addColumn(ColumnDefinition(name: "status", dataType: ""))
        draft.addColumn(ColumnDefinition(name: "flag", dataType: "boolean", isNullable: false, defaultValue: "NULL"))
        draft.addColumn(ColumnDefinition(name: "code", dataType: "text", isAutoIncrement: true))
        draft.addIndex(IndexDefinition(name: "", columns: []))
        draft.addIndex(IndexDefinition(name: "bad", columns: ["missing"]))
        draft.addForeignKey(ForeignKeyDefinition(name: "fk", columns: ["user_id", "id"], referencedTable: TableRef(name: ""), referencedColumns: ["id"]))
        let problems = generator.problems(draft)
        #expect(problems.contains("Column 5 needs a name."))
        #expect(problems.contains("Column “status” needs a type."))
        #expect(problems.contains("Column “flag” is NOT NULL, so its default cannot be NULL."))
        #expect(problems.contains("Column “code”: auto increment needs an integer type (smallint, integer or bigint)."))
        #expect(problems.contains("Two columns are named “status”."))
        #expect(problems.contains("Index 3 needs a name."))
        #expect(problems.contains("Index 3 needs at least one column."))
        #expect(problems.contains("Index “bad” uses “missing”, which is not a column of the table."))
        #expect(problems.contains("Foreign key “fk” needs a referenced table."))
        #expect(problems.contains("Foreign key “fk” lists 2 columns but 1 referenced column."))
        #expect(throws: StructureChangeError.self) { try generator.alterStatements(draft) }
    }

    @Test func createTableInlinesASingleKeyAndAddsIndexesAndCommentsAfter() throws {
        var draft = StructureDraft(newTable: TableRef(schema: "public", name: "fq_new"))
        draft.comment = "made here"
        let id = draft.addColumn(ColumnDefinition(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, isAutoIncrement: true))
        draft.addColumn(ColumnDefinition(name: "email", dataType: "varchar(255)", isNullable: false, comment: "login"))
        draft.addColumn(ColumnDefinition(name: "created", dataType: "timestamptz", defaultValue: "now()"))
        draft.addColumn(ColumnDefinition(name: "user_id", dataType: "integer"))
        draft.addColumn(ColumnDefinition(name: "", dataType: ""))
        draft.addIndex(IndexDefinition(name: "fq_new_email_key", columns: ["email"], isUnique: true))
        draft.addForeignKey(ForeignKeyDefinition(name: "fq_new_user_fk", columns: ["user_id"], referencedTable: TableRef(schema: "public", name: "users"), referencedColumns: ["id"], onDelete: .cascade))
        #expect(id == 0)
        #expect(try generator.createStatements(draft) == [
            """
            CREATE TABLE "public"."fq_new" (
                "id" bigserial PRIMARY KEY,
                "email" varchar(255) NOT NULL,
                "created" timestamptz DEFAULT now(),
                "user_id" integer,
                CONSTRAINT "fq_new_user_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users" ("id") ON DELETE CASCADE
            )
            """,
            #"CREATE UNIQUE INDEX "fq_new_email_key" ON "public"."fq_new" ("email")"#,
            #"COMMENT ON TABLE "public"."fq_new" IS 'made here'"#,
            #"COMMENT ON COLUMN "public"."fq_new"."email" IS 'login'"#,
        ])
    }

    @Test func createTableWithACompositeKeyUsesATableConstraint() throws {
        var draft = StructureDraft(newTable: TableRef(schema: "public", name: "pairs"))
        draft.addColumn(ColumnDefinition(name: "a", dataType: "integer", isNullable: false, isPrimaryKey: true))
        draft.addColumn(ColumnDefinition(name: "b", dataType: "integer", isNullable: false, isPrimaryKey: true))
        #expect(try generator.createStatements(draft) == [
            """
            CREATE TABLE "public"."pairs" (
                "a" integer NOT NULL,
                "b" integer NOT NULL,
                PRIMARY KEY ("a", "b")
            )
            """,
        ])
    }

    @Test func createTableNeedsANameAndAColumn() {
        let draft = StructureDraft(newTable: TableRef(schema: "public", name: " "))
        #expect(generator.problems(draft) == ["Enter a name for the table.", "Add at least one column."])
    }
}

@Suite struct MySQLStructureSQLTests {
    let generator = TableDDLGenerator(dialect: .mysql)

    @Test func modifyRestatesTheWholeDefinition() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.updateColumn(at: 3) { $0.comment = "last change" }
        draft.updateColumn(at: 4) { $0.dataType = "varchar(20)" }
        draft.updateColumn(at: 2) { $0.defaultValue = "uuid()" }
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `orders` MODIFY COLUMN `status` varchar(20) NOT NULL DEFAULT (uuid())",
            "ALTER TABLE `orders` MODIFY COLUMN `touched` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'last change'",
            "ALTER TABLE `orders` MODIFY COLUMN `code` varchar(20) COLLATE utf8mb4_bin NULL COMMENT 'short'",
        ])
    }

    @Test func renameUsesChangeColumn() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.updateColumn(at: 2) { $0.name = "state" }
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `orders` CHANGE COLUMN `status` `state` varchar(20) NOT NULL DEFAULT 'it''s'",
        ])
        #expect(draft.state(.indexes, row: 0) == .unchanged)
    }

    @Test func addAndDropColumns() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 4))
        draft.addColumn(ColumnDefinition(name: "total", dataType: "decimal(10,2)", isNullable: false, defaultValue: "0", comment: "sum"))
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `orders` DROP COLUMN `code`",
            "ALTER TABLE `orders` ADD COLUMN `total` decimal(10,2) NOT NULL DEFAULT 0 COMMENT 'sum'",
        ])
    }

    @Test func keyChangesTravelWithColumnChangesInOneStatement() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.updateColumn(at: 0) { $0.isPrimaryKey = false; $0.isAutoIncrement = false }
        let index = draft.addColumn(ColumnDefinition(name: "uid", dataType: "bigint", isNullable: false))
        draft.updateColumn(at: index) { $0.isPrimaryKey = true; $0.isAutoIncrement = true }
        #expect(try generator.alterStatements(draft) == [
            """
            ALTER TABLE `orders`
                DROP PRIMARY KEY,
                MODIFY COLUMN `id` int NOT NULL,
                ADD COLUMN `uid` bigint NOT NULL AUTO_INCREMENT,
                ADD PRIMARY KEY (`uid`)
            """,
        ])

        var composite = StructureDraft(structure: mysqlOrders(), family: .mysql)
        composite.updateColumn(at: 1) { $0.isPrimaryKey = true }
        #expect(try generator.alterStatements(composite) == [
            "ALTER TABLE `orders`\n    DROP PRIMARY KEY,\n    ADD PRIMARY KEY (`id`, `user_id`)",
        ])
    }

    @Test func indexesUseAlterTableAndKeepTheirKind() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.toggleDeletion(.indexes, rows: IndexSet(integer: 0))
        draft.addIndex(IndexDefinition(name: "code_uq", columns: ["CODE"], isUnique: true))
        draft.addIndex(IndexDefinition(name: "status_ft", columns: ["status"], method: "FULLTEXT"))
        draft.addIndex(IndexDefinition(name: "status_prefix", columns: ["status(5)"], method: "HASH"))
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `orders` DROP INDEX `status_idx`",
            "ALTER TABLE `orders` ADD UNIQUE INDEX `code_uq` (`code`)",
            "ALTER TABLE `orders` ADD FULLTEXT INDEX `status_ft` (`status`)",
            "ALTER TABLE `orders` ADD INDEX `status_prefix` (`status`(5)) USING HASH",
        ])
    }

    @Test func foreignKeysAndTableComment() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.updateForeignKey(at: 0) { $0.onUpdate = .noAction }
        draft.comment = "orders"
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `orders` DROP FOREIGN KEY `fk_user`",
            "ALTER TABLE `orders` ADD CONSTRAINT `fk_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE",
            "ALTER TABLE `orders` COMMENT = 'orders'",
        ])
        draft.comment = nil
        draft.revert(.foreignKeys, row: 0)
        draft.comment = "orders"
        draft.comment = ""
        #expect(try generator.alterStatements(draft) == [])
    }

    @Test func generatedColumnsAreRestatedWithTheirExpression() throws {
        let structure = TableStructure(table: TableRef(name: "g"), columns: [
            ColumnInfo(name: "b", dataType: "int"),
            ColumnInfo(name: "m", dataType: "int", extra: "VIRTUAL GENERATED", generationExpression: "(`b` + 1)"),
        ])
        var draft = StructureDraft(structure: structure, family: .mysql)
        draft.updateColumn(at: 1) { $0.comment = "derived" }
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `g` MODIFY COLUMN `m` int GENERATED ALWAYS AS ((`b` + 1)) VIRTUAL NULL COMMENT 'derived'",
        ])
    }

    @Test func mysqlRefusesPrimaryAsAnIndexNameAndSetDefault() {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.addIndex(IndexDefinition(name: "primary", columns: ["id"]))
        draft.addForeignKey(ForeignKeyDefinition(name: "f", columns: ["user_id"], referencedTable: TableRef(name: "users"), referencedColumns: ["id"], onDelete: .setDefault))
        draft.addColumn(ColumnDefinition(name: "STATUS", dataType: "int"))
        let problems = generator.problems(draft)
        #expect(problems.contains("An index cannot be named PRIMARY. Use the Primary Key checkboxes in Columns."))
        #expect(problems.contains("Foreign key “f”: MySQL does not support SET DEFAULT."))
        #expect(problems.contains("Two columns are named “STATUS”."))
    }

    @Test func createTableHasInlineKeysAndOptions() throws {
        var draft = StructureDraft(newTable: TableRef(name: "fq_new"))
        draft.comment = "made here"
        draft.addColumn(ColumnDefinition(name: "id", dataType: "int", isNullable: false, isAutoIncrement: true))
        draft.addColumn(ColumnDefinition(name: "email", dataType: "varchar(255)", isNullable: false, defaultValue: "''", comment: "login"))
        draft.addColumn(ColumnDefinition(name: "user_id", dataType: "int"))
        draft.addIndex(IndexDefinition(name: "email_uq", columns: ["email"], isUnique: true))
        draft.addIndex(IndexDefinition(name: "user_idx", columns: ["user_id"]))
        draft.addForeignKey(ForeignKeyDefinition(name: "fk_user", columns: ["user_id"], referencedTable: TableRef(name: "users"), referencedColumns: ["id"], onDelete: .setNull))
        #expect(try generator.createStatements(draft, options: .mysqlDefaults) == [
            """
            CREATE TABLE `fq_new` (
                `id` int NOT NULL AUTO_INCREMENT,
                `email` varchar(255) NOT NULL DEFAULT '' COMMENT 'login',
                `user_id` int NULL,
                PRIMARY KEY (`id`),
                UNIQUE KEY `email_uq` (`email`),
                KEY `user_idx` (`user_id`),
                CONSTRAINT `fk_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='made here'
            """,
        ])
    }

    @Test func scriptErrorsExplainWhatHappened() {
        let mysql = SchemaScriptError(statement: "ALTER TABLE `t` ADD x", position: 3, total: 4, rolledBack: false, underlying: DatabaseError.server(message: "boom", code: "1064"))
        #expect(mysql.localizedDescription.contains("Statement 3 of 4 failed"))
        #expect(mysql.localizedDescription.contains("The 2 statements before it stay applied"))
        let postgres = SchemaScriptError(statement: "x", position: 1, total: 2, rolledBack: true, underlying: DatabaseError.server(message: "boom", code: nil))
        #expect(postgres.localizedDescription.contains("rolled back"))
        #expect(TableDDLGenerator.script(["A", "B"]) == "A;\nB;")
        #expect(TableDDLGenerator(kind: .mariadb) == nil)
    }
}
