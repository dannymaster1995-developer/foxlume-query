import Foundation

// Column data types per dialect (spec 6.5, 6.6), sorted A–Z. PostgreSQL names resolve with to_regtype (except the
// serial pseudo-types, which only work in column definitions) and DuckDB names appear in duckdb_types().

extension SQLCompletionVocabulary {
    static let fallbackTypes = sortedTypes([
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL", "VARCHAR",
        "CHAR", "TEXT", "DATE", "TIME", "DATETIME", "TIMESTAMP", "BOOLEAN", "BOOL", "BLOB", "JSON", "UUID",
    ])

    static let mysqlTypes = sortedTypes([
        "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "BIT",
        "BOOLEAN", "BOOL", "DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR", "CHAR", "VARCHAR", "BINARY", "VARBINARY",
        "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB", "ENUM", "SET", "JSON",
        "GEOMETRY", "POINT",
    ])

    static let postgresqlTypes = sortedTypes([
        // Numeric
        "SMALLINT", "INTEGER", "INT", "BIGINT", "INT2", "INT4", "INT8", "DECIMAL", "NUMERIC", "REAL", "DOUBLE PRECISION",
        "FLOAT", "FLOAT4", "FLOAT8", "SMALLSERIAL", "SERIAL", "BIGSERIAL", "SERIAL2", "SERIAL4", "SERIAL8", "MONEY",
        // Character and binary
        "CHAR", "CHARACTER", "VARCHAR", "CHARACTER VARYING", "TEXT", "BPCHAR", "NAME", "BYTEA",
        // Date/time and boolean
        "DATE", "TIME", "TIMETZ", "TIME WITH TIME ZONE", "TIME WITHOUT TIME ZONE", "TIMESTAMP", "TIMESTAMPTZ",
        "TIMESTAMP WITH TIME ZONE", "TIMESTAMP WITHOUT TIME ZONE", "INTERVAL", "BOOLEAN", "BOOL",
        // Geometric and network
        "POINT", "LINE", "LSEG", "BOX", "PATH", "POLYGON", "CIRCLE", "INET", "CIDR", "MACADDR", "MACADDR8",
        // Bit strings, text search, UUID, XML, JSON
        "BIT", "BIT VARYING", "VARBIT", "TSVECTOR", "TSQUERY", "UUID", "XML", "JSON", "JSONB", "JSONPATH",
        // Ranges and multiranges
        "INT4RANGE", "INT8RANGE", "NUMRANGE", "TSRANGE", "TSTZRANGE", "DATERANGE",
        "INT4MULTIRANGE", "INT8MULTIRANGE", "NUMMULTIRANGE", "TSMULTIRANGE", "TSTZMULTIRANGE", "DATEMULTIRANGE",
        // Object identifiers
        "OID", "REGCLASS", "REGCOLLATION", "REGCONFIG", "REGDICTIONARY", "REGNAMESPACE", "REGOPER", "REGOPERATOR",
        "REGPROC", "REGPROCEDURE", "REGROLE", "REGTYPE",
        // System
        "PG_LSN", "PG_SNAPSHOT", "TXID_SNAPSHOT", "REFCURSOR",
    ])

    /// SQLite accepts any type name; these are the words its affinity rules recognize, written one word at a time
    /// so phrases like `UNSIGNED BIG INT` and `NATIVE CHARACTER` complete word by word. `ANY` is for STRICT tables.
    static let sqliteTypes = sortedTypes([
        "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "UNSIGNED", "BIG", "INT2", "INT8", "CHARACTER",
        "VARCHAR", "VARYING", "NCHAR", "NATIVE", "NVARCHAR", "TEXT", "CLOB", "BLOB", "REAL", "DOUBLE", "PRECISION", "FLOAT",
        "NUMERIC", "DECIMAL", "BOOLEAN", "DATE", "DATETIME", "ANY",
    ])

    /// Canonical names plus the aliases people type from other engines (TEXT, INT, BOOL, DATETIME, …).
    static let duckdbTypes = sortedTypes([
        "BIGINT", "BIT", "BLOB", "BOOLEAN", "DATE", "DECIMAL", "DOUBLE", "ENUM", "FLOAT", "HUGEINT", "INTEGER", "INTERVAL",
        "JSON", "LIST", "MAP", "SMALLINT", "STRUCT", "TIME", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "TIMESTAMPTZ",
        "TINYINT", "UBIGINT", "UHUGEINT", "UINTEGER", "UNION", "USMALLINT", "UTINYINT", "UUID", "VARCHAR",
        // Aliases
        "BOOL", "BYTEA", "CHAR", "DATETIME", "INT", "NUMERIC", "REAL", "STRING", "TEXT", "TIMESTAMP_MS", "TIMESTAMP_NS",
        "TIMESTAMP_S", "TIMETZ",
    ])

    /// Types a bare `x::type` rejects: column-definition shorthands that are not real types (serials), and types
    /// that need parameters (DuckDB's nested types and ENUM, MySQL's SET).
    static let castExcludedTypes: Set<String> = [
        "SMALLSERIAL", "SERIAL", "BIGSERIAL", "SERIAL2", "SERIAL4", "SERIAL8",
        "ENUM", "LIST", "MAP", "STRUCT", "UNION", "SET",
    ]

    private static func sortedTypes(_ types: [String]) -> [String] {
        types.sorted()
    }
}
