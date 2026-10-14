import Foundation
import Testing
@testable import FoxlumeQueryCore

/// The bulk catalog reader behind the ER diagram, checked against the per-table reader on scratch `fq_erd_` tables
/// that every test creates and drops.
private func scratchPrefix() -> String {
    "fq_erd_" + UUID().uuidString.prefix(6).lowercased() + "_"
}

/// What both readers must agree on: columns (name, type, nullability, key) and foreign keys.
private func summary(_ structure: TableStructure) -> [String] {
    var lines = structure.columns.map { "\($0.name) \($0.dataType) \($0.isNullable ? "null" : "not null")\($0.isPrimaryKey ? " pk" : "")" }
    lines += structure.foreignKeys.map {
        "fk \($0.name) (\($0.columns.joined(separator: ","))) -> \($0.referencedTable.schema ?? "-").\($0.referencedTable.name) (\($0.referencedColumns.joined(separator: ","))) \($0.onDelete ?? "-")"
    }.sorted()
    return lines
}

private func checkAgainstPerTableReader(_ connection: DatabaseConnection, schema: String?, prefix: String) throws -> ERDiagramGraph {
    let bulk = try #require(try connection.diagramStructures(schema: schema))
    let scratch = bulk.filter { $0.table.name.hasPrefix(prefix) }
    #expect(scratch.map(\.table.name) == ["parent", "child", "profile", "tree", "link"].map { prefix + $0 }.sorted())
    for structure in scratch {
        #expect(structure.table.schema == schema)
        let single = try connection.structure(of: structure.table)
        #expect(summary(structure) == summary(single), "\(structure.table.name)")
        // Every unique key the bulk reader keeps is one the table really has (it leaves out expression and partial ones).
        let singleKeys = Set(single.indexes.filter { $0.isUnique || $0.isPrimary }.map(\.columns))
        #expect(structure.indexes.allSatisfy { singleKeys.contains($0.columns) }, "\(structure.table.name)")
    }
    let tables = try connection.tables(schema: schema).filter { $0.name.hasPrefix(prefix) }
    return ERDiagramGraph.build(tables: tables, structures: scratch)
}

private func checkGraph(_ graph: ERDiagramGraph, prefix: String) {
    let byName = Dictionary(uniqueKeysWithValues: graph.relationships.map { ($0.name, $0) })
    #expect(graph.relationships.count == 5)
    // child.parent_id is NOT NULL and not unique: one or many.
    #expect(byName["\(prefix)child_parent_fk"]?.cardinality == ERCardinality(isUnique: false, isMandatory: true))
    #expect(byName["\(prefix)child_parent_fk"]?.to == "\(prefix)parent")
    // profile's key is its primary key: one to one.
    #expect(byName["\(prefix)profile_parent_fk"]?.cardinality == ERCardinality(isUnique: true, isMandatory: true))
    // A nullable self reference.
    #expect(byName["\(prefix)tree_up_fk"]?.isSelfReference == true)
    #expect(byName["\(prefix)tree_up_fk"]?.cardinality.isMandatory == false)
    // The composite key keeps its column order on both sides.
    #expect(byName["\(prefix)link_child_fk"]?.fromColumns == ["child_parent", "child_seq"])
    #expect(byName["\(prefix)link_child_fk"]?.toColumns == ["parent_id", "seq"])
    // A unique (not primary) key column.
    #expect(byName["\(prefix)link_tree_fk"]?.cardinality == ERCardinality(isUnique: true, isMandatory: false))
    #expect(graph.groups["\(prefix)parent"] == graph.groups["\(prefix)link"])
    #expect(graph.groups["\(prefix)parent"] != nil)
}

@Suite("ER diagram metadata on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresDiagramLiveTests {
    @Test func bulkReaderMatchesPerTableReader() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let p = scratchPrefix()
        defer {
            _ = try? connection.execute("DROP TABLE IF EXISTS \(["link", "tree", "profile", "child", "parent"].map { "public.\(p)\($0)" }.joined(separator: ", "))", rowLimit: nil)
        }
        _ = try connection.execute("""
            CREATE TABLE public.\(p)parent (id integer PRIMARY KEY, name text NOT NULL);
            CREATE TABLE public.\(p)child (parent_id integer NOT NULL, seq integer NOT NULL, note varchar(40),
              PRIMARY KEY (parent_id, seq),
              CONSTRAINT \(p)child_parent_fk FOREIGN KEY (parent_id) REFERENCES public.\(p)parent (id) ON DELETE CASCADE);
            CREATE TABLE public.\(p)profile (parent_id integer PRIMARY KEY, bio text,
              CONSTRAINT \(p)profile_parent_fk FOREIGN KEY (parent_id) REFERENCES public.\(p)parent (id));
            CREATE TABLE public.\(p)tree (id integer PRIMARY KEY, up integer, code text,
              CONSTRAINT \(p)tree_up_fk FOREIGN KEY (up) REFERENCES public.\(p)tree (id));
            CREATE UNIQUE INDEX \(p)tree_lower ON public.\(p)tree (lower(code));
            CREATE TABLE public.\(p)link (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              child_parent integer, child_seq integer, tree_id integer UNIQUE, extra integer,
              CONSTRAINT \(p)link_child_fk FOREIGN KEY (child_parent, child_seq) REFERENCES public.\(p)child (parent_id, seq),
              CONSTRAINT \(p)link_tree_fk FOREIGN KEY (tree_id) REFERENCES public.\(p)tree (id));
            CREATE UNIQUE INDEX \(p)link_partial ON public.\(p)link (extra) WHERE extra > 0;
            """, rowLimit: nil)

        let graph = try checkAgainstPerTableReader(connection, schema: "public", prefix: p)
        checkGraph(graph, prefix: p)
        // Expression and partial unique indexes say nothing about a plain column set.
        let bulk = try #require(try connection.diagramStructures(schema: "public"))
        #expect(bulk.first { $0.table.name == "\(p)tree" }?.indexes.map(\.name) == ["\(p)tree_pkey"])
        #expect(bulk.first { $0.table.name == "\(p)link" }?.indexes.contains { $0.name == "\(p)link_partial" } == false)
        // The sample schema's own key.
        let orders = bulk.first { $0.table.name == "orders" }
        #expect(orders?.foreignKeys.first?.referencedTable == TableRef(schema: "public", name: "users"))
    }

    @Test func defaultSchemaAndEmptySchema() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let structures = try #require(try connection.diagramStructures(schema: nil))
        #expect(structures.allSatisfy { $0.table.schema == "public" })
        #expect(try connection.diagramStructures(schema: "fq_erd_no_such_schema")?.isEmpty == true)
    }
}

@Suite("ER diagram metadata on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLDiagramLiveTests {
    @Test func bulkReaderMatchesPerTableReader() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let p = scratchPrefix()
        defer {
            for name in ["link", "tree", "profile", "child", "parent"] {
                _ = try? connection.execute("DROP TABLE IF EXISTS `\(p)\(name)`", rowLimit: nil)
            }
        }
        for statement in [
            "CREATE TABLE `\(p)parent` (id int PRIMARY KEY, name varchar(50) NOT NULL)",
            "CREATE TABLE `\(p)child` (parent_id int NOT NULL, seq int NOT NULL, note varchar(40), PRIMARY KEY (parent_id, seq), CONSTRAINT `\(p)child_parent_fk` FOREIGN KEY (parent_id) REFERENCES `\(p)parent` (id) ON DELETE CASCADE)",
            "CREATE TABLE `\(p)profile` (parent_id int PRIMARY KEY, bio text, CONSTRAINT `\(p)profile_parent_fk` FOREIGN KEY (parent_id) REFERENCES `\(p)parent` (id))",
            "CREATE TABLE `\(p)tree` (id int PRIMARY KEY, up int, code varchar(20), CONSTRAINT `\(p)tree_up_fk` FOREIGN KEY (up) REFERENCES `\(p)tree` (id), UNIQUE KEY `\(p)tree_lower` ((lower(code))))",
            "CREATE TABLE `\(p)link` (id int AUTO_INCREMENT PRIMARY KEY, child_parent int, child_seq int, tree_id int UNIQUE, CONSTRAINT `\(p)link_child_fk` FOREIGN KEY (child_parent, child_seq) REFERENCES `\(p)child` (parent_id, seq), CONSTRAINT `\(p)link_tree_fk` FOREIGN KEY (tree_id) REFERENCES `\(p)tree` (id))",
        ] {
            _ = try connection.execute(statement, rowLimit: nil)
        }

        let graph = try checkAgainstPerTableReader(connection, schema: nil, prefix: p)
        checkGraph(graph, prefix: p)
        // A functional unique key is left out; naming the database gives references that carry it.
        let named = try #require(try connection.diagramStructures(schema: "foxlume"))
        let tree = named.first { $0.table.name == "\(p)tree" }
        #expect(tree?.indexes.map(\.name) == ["PRIMARY"])
        #expect(tree?.table.schema == "foxlume")
        #expect(tree?.foreignKeys.first?.referencedTable == TableRef(schema: "foxlume", name: "\(p)tree"))
        let orders = named.first { $0.table.name == "orders" }
        #expect(orders?.foreignKeys.first?.referencedTable.name == "users")
    }
}
