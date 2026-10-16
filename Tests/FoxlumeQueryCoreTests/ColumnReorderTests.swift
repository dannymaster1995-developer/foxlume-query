import Foundation
import Testing
@testable import FoxlumeQueryCore

/// The MySQL `orders` table of StructureChangeTests: literal defaults unquoted, expression defaults flagged in EXTRA.
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
        indexes: [IndexInfo(name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true, method: "BTREE")]
    )
}

/// A PostgreSQL table with an identity key, a serial column, a collated and commented column, and its rebuild info.
private func postgresLines() -> (TableStructure, TableRebuildInfo) {
    let table = TableRef(schema: "public", name: "lines")
    let structure = TableStructure(
        table: table,
        columns: [
            ColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, extra: "GENERATED ALWAYS AS IDENTITY"),
            ColumnInfo(name: "line_no", dataType: "integer", isNullable: false, defaultValue: "nextval('lines_line_no_seq'::regclass)", isAutoIncrement: true),
            ColumnInfo(name: "note", dataType: "character varying(20)", comment: "free text", collation: "C"),
            ColumnInfo(name: "doubled", dataType: "bigint", extra: "GENERATED ALWAYS AS ((id * 2)) STORED", generationExpression: "(id * 2)"),
        ],
        indexes: [IndexInfo(name: "lines_pkey", columns: ["id"], isUnique: true, isPrimary: true, method: "btree")],
        comment: "Order lines"
    )
    let info = TableRebuildInfo(
        table: table,
        columns: [
            .init(name: "id", dataType: "bigint", isNotNull: true, notNullConstraint: "lines_id_not_null", identity: "a",
                  identitySequence: TableRef(schema: "public", name: "lines_id_seq"),
                  identityOptions: "START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE"),
            .init(name: "line_no", dataType: "integer", isNotNull: true, defaultExpression: "nextval('lines_line_no_seq'::regclass)"),
            .init(name: "note", dataType: "character varying(20)", collation: "\"C\"", comment: "free text",
                  privileges: [.init(grantee: "reader", privilege: "UPDATE")]),
            .init(name: "doubled", dataType: "bigint", generationExpression: "(id * 2)", generationKind: "s"),
        ],
        constraints: [
            .init(name: "lines_parent_fk", kind: "f", definition: "FOREIGN KEY (line_no) REFERENCES parents(id)"),
            .init(name: "lines_note_check", kind: "c", definition: "CHECK ((note <> ''::text))", comment: "no empty notes"),
            .init(name: "lines_pkey", kind: "p", definition: "PRIMARY KEY (id)"),
        ],
        indexes: [.init(name: "lines_note_idx", definition: "CREATE INDEX lines_note_idx ON public.lines USING btree (note) WHERE (note IS NOT NULL)", comment: "partial")],
        ownedSequences: [.init(sequence: TableRef(schema: "public", name: "lines_line_no_seq"), column: "line_no")],
        comment: "Order lines",
        owner: "app_owner",
        privileges: [.init(grantee: "reader", privilege: "SELECT"), .init(grantee: "reader", privilege: "INSERT"), .init(grantee: nil, privilege: "SELECT", isGrantable: false)],
        options: ["fillfactor=70"],
        replicaIdentity: "f"
    )
    return (structure, info)
}

@Suite struct ColumnReorderDraftTests {
    @Test func movingRowsWorksLikeATableViewDrop() {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        // The last column to the top.
        #expect(draft.moveColumns(IndexSet(integer: 4), to: 0) == 0..<1)
        #expect(draft.columns.map(\.current.name) == ["code", "id", "user_id", "status", "touched"])
        // Two rows below the next one: the destination counts rows before the move.
        #expect(draft.moveColumns(IndexSet([1, 2]), to: 4) == 2..<4)
        #expect(draft.columns.map(\.current.name) == ["code", "status", "id", "user_id", "touched"])
        // Out of range or nothing to move changes nothing.
        let before = draft
        draft.moveColumns(IndexSet(integer: 9), to: 0)
        draft.moveColumns(IndexSet(integer: 0), to: 7)
        #expect(draft == before)
    }

    @Test func onlyTheDraggedColumnCountsAsMoved() {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.moveColumns(IndexSet(integer: 4), to: 0)
        #expect(draft.columnOrderChanged)
        #expect(draft.isColumnMoved(row: 0))
        #expect((1...4).allSatisfy { !draft.isColumnMoved(row: $0) })
        #expect(draft.state(.columns, row: 0) == .modified)
        #expect(draft.state(.columns, row: 1) == .unchanged)
        #expect(draft.changeCount == 1)

        // Moving the first column down marks that one, not the ones that slid up.
        var down = StructureDraft(structure: mysqlOrders(), family: .mysql)
        down.moveColumns(IndexSet(integer: 0), to: 2)
        #expect(down.columns.map(\.current.name) == ["user_id", "id", "status", "touched", "code"])
        #expect(down.isColumnMoved(row: 1))
        #expect(down.changeCount == 1)

        // Moving it back clears the change.
        down.moveColumns(IndexSet(integer: 1), to: 0)
        #expect(!down.hasChanges)
    }

    @Test func aColumnChangedAnywayIsTheOneThatMoves() {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.updateColumn(at: 1) { $0.comment = "owner" }
        // Swapping id and user_id: either could move; user_id needs a MODIFY anyway.
        draft.moveColumns(IndexSet(integer: 1), to: 0)
        #expect(draft.isColumnMoved(row: 0))
        #expect(!draft.isColumnMoved(row: 1))
        #expect(draft.changeCount == 1)
    }

    @Test func deletedAndNewColumnsAreNotMoves() {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 4))
        draft.moveColumns(IndexSet(integer: 4), to: 0)
        #expect(!draft.columnOrderChanged)
        let added = draft.addColumn(ColumnDefinition(name: "extra", dataType: "int"))
        #expect(draft.newColumnsAmongExisting.isEmpty)
        draft.moveColumns(IndexSet(integer: added), to: 1)
        #expect(!draft.columnOrderChanged)
        #expect(draft.newColumnsAmongExisting.map(\.name) == ["extra"])
        #expect(draft.changeCount == 2)
    }

    @Test func revertPutsAMovedColumnBack() {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.moveColumns(IndexSet(integer: 3), to: 0)
        draft.updateColumn(at: 0) { $0.comment = "changed" }
        draft.revert(.columns, row: 0)
        #expect(draft.columns.map(\.current.name) == ["id", "user_id", "status", "touched", "code"])
        #expect(!draft.hasChanges)

        // With other columns moved meanwhile, it goes back after the column before it on the server.
        draft.moveColumns(IndexSet(integer: 0), to: 5)
        draft.moveColumns(IndexSet(integer: 3), to: 0)
        #expect(draft.columns.map(\.current.name) == ["code", "user_id", "status", "touched", "id"])
        draft.revert(.columns, row: 4)
        #expect(draft.columns.map(\.current.name) == ["id", "code", "user_id", "status", "touched"])
        #expect(draft.changeCount == 1)

        // Several rows at once, each found again after the one before it went back.
        draft.moveColumns(IndexSet(integer: 4), to: 0)
        #expect(draft.columns.map(\.current.name) == ["touched", "id", "code", "user_id", "status"])
        draft.revert(.columns, rows: IndexSet([0, 2]))
        #expect(draft.columns.map(\.current.name) == ["id", "user_id", "status", "touched", "code"])
        #expect(!draft.hasChanges)
    }
}

@Suite struct MySQLColumnReorderSQLTests {
    let generator = TableDDLGenerator(dialect: .mysql)

    @Test func aMovedColumnIsRestatedInFullWithItsPosition() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.moveColumns(IndexSet(integer: 4), to: 0)
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `orders` MODIFY COLUMN `code` varchar(10) COLLATE utf8mb4_bin NULL COMMENT 'short' FIRST",
        ])

        var after = StructureDraft(structure: mysqlOrders(), family: .mysql)
        after.moveColumns(IndexSet(integer: 0), to: 4)
        #expect(try generator.alterStatements(after) == [
            "ALTER TABLE `orders` MODIFY COLUMN `id` int NOT NULL AUTO_INCREMENT AFTER `touched`",
        ])
    }

    @Test func severalMovesTakeTheFewestClausesInOneStatement() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        // id, user_id, status, touched, code → touched, code, id, user_id, status: two moves, not three.
        draft.moveColumns(IndexSet([3, 4]), to: 0)
        #expect(try generator.alterStatements(draft) == [
            """
            ALTER TABLE `orders`
                MODIFY COLUMN `touched` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP FIRST,
                MODIFY COLUMN `code` varchar(10) COLLATE utf8mb4_bin NULL COMMENT 'short' AFTER `touched`
            """,
        ])
    }

    @Test func movesJoinOtherChangesOfTheSameColumnAndFollowRenames() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.updateColumn(at: 2) { $0.name = "state" }
        draft.updateColumn(at: 4) { $0.dataType = "varchar(12)" }
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 1))
        // id, user_id (deleted), state, touched, code → code, state, id, touched, plus a new column after state.
        draft.moveColumns(IndexSet(integer: 4), to: 0)
        draft.moveColumns(IndexSet(integer: 3), to: 1)
        let added = draft.addColumn(ColumnDefinition(name: "region", dataType: "char(2)", isNullable: false, defaultValue: "'EU'"))
        draft.moveColumns(IndexSet(integer: added), to: 2)
        #expect(draft.columns.map(\.current.name) == ["code", "state", "region", "id", "user_id", "touched"])
        #expect(try generator.alterStatements(draft) == [
            """
            ALTER TABLE `orders`
                DROP COLUMN `user_id`,
                MODIFY COLUMN `code` varchar(12) COLLATE utf8mb4_bin NULL COMMENT 'short' FIRST,
                CHANGE COLUMN `status` `state` varchar(20) NOT NULL DEFAULT 'it''s' AFTER `code`,
                ADD COLUMN `region` char(2) NOT NULL DEFAULT 'EU' AFTER `state`
            """,
        ])
    }

    @Test func movesTravelWithAKeyChange() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.updateColumn(at: 1) { $0.isPrimaryKey = true }
        draft.moveColumns(IndexSet(integer: 1), to: 0)
        #expect(try generator.alterStatements(draft) == [
            """
            ALTER TABLE `orders`
                DROP PRIMARY KEY,
                MODIFY COLUMN `user_id` int NOT NULL FIRST,
                ADD PRIMARY KEY (`id`, `user_id`)
            """,
        ])
    }

    @Test func aNewColumnAtTheEndNeedsNoPosition() throws {
        var draft = StructureDraft(structure: mysqlOrders(), family: .mysql)
        draft.addColumn(ColumnDefinition(name: "a", dataType: "int"))
        let second = draft.addColumn(ColumnDefinition(name: "b", dataType: "int"))
        draft.moveColumns(IndexSet(integer: second), to: 5)
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `orders` ADD COLUMN `b` int NULL",
            "ALTER TABLE `orders` ADD COLUMN `a` int NULL",
        ])
    }

    @Test func generatedColumnsMoveWithTheirExpression() throws {
        let structure = TableStructure(table: TableRef(name: "g"), columns: [
            ColumnInfo(name: "b", dataType: "int"),
            ColumnInfo(name: "m", dataType: "int", extra: "STORED GENERATED", generationExpression: "(`b` + 1)"),
        ])
        var draft = StructureDraft(structure: structure, family: .mysql)
        draft.moveColumns(IndexSet(integer: 1), to: 0)
        #expect(try generator.alterStatements(draft) == [
            "ALTER TABLE `g` MODIFY COLUMN `m` int GENERATED ALWAYS AS ((`b` + 1)) STORED NULL FIRST",
        ])
    }

    @Test func newTablesUseTheListOrder() throws {
        let generator = TableDDLGenerator(dialect: .postgresql)
        var draft = StructureDraft(newTable: TableRef(schema: "public", name: "t"))
        draft.addColumn(ColumnDefinition(name: "a", dataType: "integer"))
        draft.addColumn(ColumnDefinition(name: "b", dataType: "text"))
        draft.addColumn(ColumnDefinition(name: "c", dataType: "date"))
        draft.moveColumns(IndexSet(integer: 2), to: 0)
        #expect(!draft.columnOrderChanged)
        #expect(generator.problems(draft).isEmpty)
        #expect(try generator.createStatements(draft) == ["CREATE TABLE \"public\".\"t\" (\n    \"c\" date,\n    \"a\" integer,\n    \"b\" text\n)"])
        let mysql = TableDDLGenerator(dialect: .mysql)
        #expect(try mysql.createStatements(draft).first?.hasPrefix("CREATE TABLE `public`.`t` (\n    `c` date NULL,\n    `a` integer NULL") == true)
    }
}

@Suite struct PostgresColumnReorderSQLTests {
    let generator = TableDDLGenerator(dialect: .postgresql)

    @Test func aReorderNeedsTheRebuildInfoAndNoBlockers() {
        let (structure, info) = postgresLines()
        var draft = StructureDraft(structure: structure, family: .postgresql)
        draft.moveColumns(IndexSet(integer: 2), to: 0)
        #expect(generator.needsRebuild(draft))
        #expect(generator.problems(draft).first?.hasPrefix("PostgreSQL cannot reorder columns of an existing table until") == true)
        #expect(generator.problems(draft, rebuild: info).isEmpty)

        var blocked = info
        blocked.blockers = ["views depend on it (public.v)", "it has triggers (audit)"]
        #expect(blocked.blockerSentence == "PostgreSQL cannot reorder the columns of this table: views depend on it (public.v); it has triggers (audit).")
        #expect(throws: StructureChangeError.incomplete([blocked.blockerSentence!])) {
            try generator.alterStatements(draft, rebuild: blocked)
        }

        var stale = info
        stale.columns.removeLast()
        #expect(generator.problems(draft, rebuild: stale) == ["The columns of lines changed on the server. Reload the structure and try again."])

        // Without a reorder nothing is rebuilt, whatever the info says.
        let plain = StructureDraft(structure: structure, family: .postgresql)
        #expect(!generator.needsRebuild(plain))
        #expect(generator.problems(plain, rebuild: blocked).isEmpty)
    }

    @Test func newColumnsMustStayAtTheEnd() {
        let (structure, info) = postgresLines()
        var draft = StructureDraft(structure: structure, family: .postgresql)
        let added = draft.addColumn(ColumnDefinition(name: "qty", dataType: "integer"))
        #expect(generator.problems(draft, rebuild: info).isEmpty)
        draft.moveColumns(IndexSet(integer: added), to: 1)
        #expect(generator.problems(draft, rebuild: info) == [
            "PostgreSQL adds new columns at the end of the table: move “qty” below the existing columns, or save it first and move it afterwards.",
        ])
    }

    @Test func theRebuildCopiesTheTableAndPutsEverythingBack() throws {
        let (structure, info) = postgresLines()
        var draft = StructureDraft(structure: structure, family: .postgresql)
        draft.moveColumns(IndexSet(integer: 2), to: 0)
        #expect(try generator.alterStatements(draft, rebuild: info) == [
            "LOCK TABLE \"public\".\"lines\" IN ACCESS EXCLUSIVE MODE",
            """
            CREATE TABLE "public"."lines_fq_reorder" (
                "note" character varying(20) COLLATE "C",
                "id" bigint GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME "public"."lines_id_seq_fq_reorder" START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE) CONSTRAINT "lines_id_not_null" NOT NULL,
                "line_no" integer DEFAULT nextval('lines_line_no_seq'::regclass) NOT NULL,
                "doubled" bigint GENERATED ALWAYS AS ((id * 2)) STORED
            ) WITH (fillfactor=70)
            """,
            "INSERT INTO \"public\".\"lines_fq_reorder\" (\"note\", \"id\", \"line_no\") OVERRIDING SYSTEM VALUE SELECT \"note\", \"id\", \"line_no\" FROM \"public\".\"lines\"",
            "SELECT pg_catalog.setval('\"public\".\"lines_id_seq_fq_reorder\"', last_value, is_called) FROM \"public\".\"lines_id_seq\"",
            "ALTER SEQUENCE \"public\".\"lines_line_no_seq\" OWNED BY NONE",
            "DROP TABLE \"public\".\"lines\"",
            "ALTER TABLE \"public\".\"lines_fq_reorder\" RENAME TO \"lines\"",
            "ALTER SEQUENCE \"public\".\"lines_id_seq_fq_reorder\" RENAME TO \"lines_id_seq\"",
            "ALTER SEQUENCE \"public\".\"lines_line_no_seq\" OWNED BY \"public\".\"lines\".\"line_no\"",
            "ALTER TABLE \"public\".\"lines\" ADD CONSTRAINT \"lines_pkey\" PRIMARY KEY (id)",
            "ALTER TABLE \"public\".\"lines\" ADD CONSTRAINT \"lines_note_check\" CHECK ((note <> ''::text))",
            "ALTER TABLE \"public\".\"lines\" ADD CONSTRAINT \"lines_parent_fk\" FOREIGN KEY (line_no) REFERENCES parents(id)",
            "CREATE INDEX lines_note_idx ON public.lines USING btree (note) WHERE (note IS NOT NULL)",
            "ALTER TABLE \"public\".\"lines\" REPLICA IDENTITY FULL",
            "ALTER TABLE \"public\".\"lines\" OWNER TO \"app_owner\"",
            "GRANT SELECT, INSERT ON TABLE \"public\".\"lines\" TO \"reader\"",
            "GRANT SELECT ON TABLE \"public\".\"lines\" TO PUBLIC",
            "GRANT UPDATE (\"note\") ON TABLE \"public\".\"lines\" TO \"reader\"",
            "COMMENT ON TABLE \"public\".\"lines\" IS 'Order lines'",
            "COMMENT ON COLUMN \"public\".\"lines\".\"note\" IS 'free text'",
            "COMMENT ON CONSTRAINT \"lines_note_check\" ON \"public\".\"lines\" IS 'no empty notes'",
            "COMMENT ON INDEX \"public\".\"lines_note_idx\" IS 'partial'",
        ])
    }

    @Test func otherChangesFollowTheRebuildUnderTheOriginalNames() throws {
        let (structure, info) = postgresLines()
        var draft = StructureDraft(structure: structure, family: .postgresql)
        draft.updateColumn(at: 2) { $0.name = "remark" }
        draft.toggleDeletion(.columns, rows: IndexSet(integer: 3))
        draft.moveColumns(IndexSet(integer: 2), to: 0)
        draft.addColumn(ColumnDefinition(name: "qty", dataType: "integer"))
        draft.comment = "Lines"
        let statements = try generator.alterStatements(draft, rebuild: info)
        // The rebuild keeps every existing column, deleted ones included, under its server name.
        #expect(statements[1].contains("\"note\" character varying(20)"))
        #expect(statements[1].contains("\"doubled\" bigint"))
        let rebuildCount = generator.rebuildStatements(draft, rebuild: info).count
        #expect(Array(statements.dropFirst(rebuildCount)) == [
            "ALTER TABLE \"public\".\"lines\" DROP COLUMN \"doubled\"",
            "ALTER TABLE \"public\".\"lines\" RENAME COLUMN \"note\" TO \"remark\"",
            "ALTER TABLE \"public\".\"lines\" ADD COLUMN \"qty\" integer",
            "COMMENT ON TABLE \"public\".\"lines\" IS 'Lines'",
        ])
    }
}
