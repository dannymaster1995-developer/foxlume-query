import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Sort and filter SQL against the local test servers, on scratch `fq_grid_` tables that each test drops again.
private func scratchTable() -> String {
    "fq_grid_" + UUID().uuidString.prefix(8).lowercased()
}

/// The ids a table query returns, in order.
private func ids(_ connection: DatabaseConnection, _ table: String, filters: [FilterRule] = [], logic: FilterLogic = .and, sort: [SortKey] = [SortKey(column: "id", ascending: true)]) throws -> [String] {
    let query = TableQuery(table: TableRef(name: table), filters: filters, filterLogic: logic, sort: sort, pageSize: 100)
    return try connection.fetchRows(query).rows.compactMap { $0.first?.textValue }
}

/// The checks both servers must pass on the same six rows.
private func checkSortAndFilters(_ connection: DatabaseConnection, _ table: String) throws {
    // Multi-key ORDER BY: group ascending, then name descending.
    #expect(try ids(connection, table, sort: [SortKey(column: "grp", ascending: true), SortKey(column: "name", ascending: false)]) == ["5", "3", "1", "4", "2", "6"])
    #expect(try ids(connection, table, sort: [SortKey(column: "grp", ascending: false), SortKey(column: "id", ascending: true)]) == ["6", "2", "4", "1", "3", "5"])

    #expect(try ids(connection, table, filters: [FilterRule(column: "price", op: .between, value: "10", secondValue: "20")]) == ["2", "5"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "price", op: .notBetween, value: "10", secondValue: "20")]) == ["1", "3", "6"])

    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .regex, value: "^al")]) == ["1", "2"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .regex, value: "^al", matchCase: true)]) == ["2"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .regex, value: "a$|_[0-9]$")]) == ["1", "2", "3", "4", "5"])

    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .contains, value: "ALP")]) == ["1", "2"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .contains, value: "Alp", matchCase: true)]) == ["1"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .startsWith, value: "a", matchCase: true)]) == ["2"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .notContains, value: "a", matchCase: true)]) == ["6"], "NULL-free names without a lowercase a")
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .endsWith, value: "_1")]) == ["5"], "the underscore is literal")

    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .isEmpty)]) == ["6"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "price", op: .isEmpty)]) == ["4"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "grp", op: .notInList, value: "1, NULL")]) == ["2", "4", "6"])
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", value: "Beta"), FilterRule(column: "grp", value: "2")], logic: .or) == ["2", "3", "4"])

    // A quote in a value is data, not SQL.
    _ = try ids(connection, table, filters: [FilterRule(column: "name", op: .between, value: "O'B", secondValue: "z'; DROP TABLE \(table); --")])
    #expect(try ids(connection, table, filters: [FilterRule(column: "name", op: .regex, value: "'")]).isEmpty)
    #expect(try ids(connection, table).count == 6)
}

@Suite("Grid sort and filters on PostgreSQL", .serialized, .enabled(if: PostgresTestServer.isAvailable, "needs the PostgreSQL test server"))
struct PostgresGridLiveTests {
    @Test func multiKeySortBetweenRegexAndMatchCase() throws {
        let connection = try PostgresTestServer.connect()
        defer { connection.close() }
        let table = scratchTable()
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(table)", rowLimit: nil) }
        _ = try connection.execute("""
            CREATE TABLE \(table) (id integer PRIMARY KEY, name text NOT NULL, grp integer, price numeric(10,2));
            INSERT INTO \(table) VALUES (1, 'Alpha', 1, 5), (2, 'alpha', 2, 15.5), (3, 'Beta', 1, 25), (4, 'gamma', 2, NULL), (5, 'Delta_1', 1, 10), (6, '', 3, 1);
            """, rowLimit: nil)
        try checkSortAndFilters(connection, table)
    }
}

@Suite("Grid sort and filters on MySQL", .serialized, .enabled(if: MySQLTestServer.isAvailable, "needs the MySQL test server"))
struct MySQLGridLiveTests {
    @Test func multiKeySortBetweenRegexAndMatchCase() throws {
        let connection = try MySQLTestServer.connect()
        defer { connection.close() }
        let table = scratchTable()
        defer { _ = try? connection.execute("DROP TABLE IF EXISTS \(table)", rowLimit: nil) }
        _ = try connection.execute("CREATE TABLE \(table) (id int PRIMARY KEY, name varchar(40) NOT NULL, grp int, price decimal(10,2))", rowLimit: nil)
        _ = try connection.execute("INSERT INTO \(table) VALUES (1, 'Alpha', 1, 5), (2, 'alpha', 2, 15.5), (3, 'Beta', 1, 25), (4, 'gamma', 2, NULL), (5, 'Delta_1', 1, 10), (6, '', 3, 1)", rowLimit: nil)
        try checkSortAndFilters(connection, table)
    }
}
