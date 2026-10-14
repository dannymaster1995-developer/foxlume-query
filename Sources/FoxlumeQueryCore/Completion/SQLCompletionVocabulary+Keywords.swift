import Foundation

extension SQLCompletionVocabulary {
    /// Same list for every SQL dialect (spec 6.2).
    static let statementStartKeywords = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT", "CREATE", "ALTER", "DROP", "TRUNCATE",
        "RENAME", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "ANALYZE", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",
        "START TRANSACTION", "WITH", "RECURSIVE", "USE", "SET", "GRANT", "REVOKE", "CALL", "EXECUTE", "PREPARE",
    ]

    static let keywordHelp: [String: String] = [
        // Querying
        "SELECT": "Chooses the columns or expressions a query returns",
        "FROM": "Names the tables, views or subqueries to read rows from",
        "WHERE": "Keeps only the rows for which a condition is true",
        "AS": "Gives a column, table or subquery another name",
        "DISTINCT": "Removes duplicate rows from the result",
        "ALL": "Keeps duplicates (the default), or compares against every value of a subquery",
        "WITH": "Defines named subqueries (CTEs), or sets storage parameters of a table or index",
        "RECURSIVE": "Lets a CTE refer to itself, for walking trees and graphs",
        "LATERAL": "Lets a subquery in FROM refer to columns of earlier FROM items",
        "VALUES": "Lists literal rows, for INSERT or as a table",
        "INTO": "Names the target table of an INSERT, or where SELECT … INTO stores its result",
        // Joins
        "JOIN": "Combines rows of two tables; an inner join unless qualified",
        "INNER JOIN": "Keeps only row pairs that satisfy the join condition",
        "LEFT JOIN": "Keeps every row of the left table, with NULLs where nothing matches",
        "RIGHT JOIN": "Keeps every row of the right table, with NULLs where nothing matches",
        "FULL JOIN": "Keeps every row of both tables, with NULLs where nothing matches",
        "LEFT OUTER JOIN": "Same as LEFT JOIN",
        "RIGHT OUTER JOIN": "Same as RIGHT JOIN",
        "FULL OUTER JOIN": "Same as FULL JOIN",
        "CROSS JOIN": "Pairs every row of one table with every row of the other",
        "NATURAL JOIN": "Joins on all columns that share a name",
        "ON": "Gives a join condition, or names the table of an index or trigger",
        "USING": "Joins on columns both tables share, or picks an index method",
        // Grouping, ordering, limiting
        "GROUP BY": "Collapses rows that share values into one row per group",
        "HAVING": "Filters groups after aggregation",
        "ORDER BY": "Sorts the result",
        "ASC": "Sorts from smallest to largest (the default)",
        "DESC": "Sorts from largest to smallest; as a statement, describes a table (MySQL)",
        "NULLS FIRST": "Puts NULLs before other values when sorting",
        "NULLS LAST": "Puts NULLs after other values when sorting",
        "LIMIT": "Caps the number of rows returned",
        "OFFSET": "Skips a number of rows before returning any",
        "FETCH": "Standard-SQL row limit: FETCH FIRST n ROWS ONLY",
        // Set operations
        "UNION": "Appends the rows of a second query, removing duplicates",
        "UNION ALL": "Appends the rows of a second query, keeping duplicates",
        "INTERSECT": "Keeps rows that both queries return",
        "EXCEPT": "Keeps rows of the first query that the second does not return",
        // Predicates and logic
        "AND": "True when both conditions are true",
        "OR": "True when either condition is true",
        "NOT": "Negates a condition",
        "IN": "Tests whether a value is in a list or subquery",
        "NOT IN": "Tests whether a value is absent from a list or subquery",
        "LIKE": "Matches a pattern where % is any text and _ is one character",
        "ILIKE": "Case-insensitive LIKE",
        "SIMILAR TO": "Matches an SQL regular-expression pattern",
        "REGEXP": "Matches a regular expression",
        "RLIKE": "Same as REGEXP",
        "BETWEEN": "Tests whether a value lies within a range, bounds included",
        "EXISTS": "True when a subquery returns at least one row",
        "NOT EXISTS": "True when a subquery returns no rows",
        "ANY": "Compares against each value of a subquery or array; true if any match",
        "SOME": "Same as ANY",
        "IS": "Tests against NULL, TRUE, FALSE or UNKNOWN",
        "IS NULL": "True when the value is NULL",
        "IS NOT NULL": "True when the value is not NULL",
        "NULL": "The missing or unknown value",
        "NOT NULL": "Disallows NULL in a column, or tests that a value is present",
        "TRUE": "Boolean true",
        "FALSE": "Boolean false",
        // Conditional expressions
        "CASE": "Starts a conditional expression",
        "WHEN": "A condition (or value) to test in CASE",
        "THEN": "The result when the preceding WHEN matches",
        "ELSE": "The result when no WHEN matches",
        "END": "Closes a CASE expression or a block",
        // Data changes
        "INSERT": "Adds rows to a table",
        "UPDATE": "Changes values in existing rows",
        "DELETE": "Removes rows from a table",
        "SET": "Assigns column values in UPDATE (or MySQL INSERT), or changes a setting",
        "DEFAULT": "The column's default value",
        "RETURNING": "Returns columns of the rows an INSERT, UPDATE or DELETE touched",
        "ON CONFLICT": "Chooses what an INSERT does when it hits a unique violation",
        "ON DUPLICATE KEY UPDATE": "Updates the existing row when an INSERT hits a duplicate key (MySQL)",
        "TRUNCATE": "Removes all rows from a table quickly",
        // Windows
        "OVER": "Turns a function into a window function over related rows",
        "PARTITION BY": "Splits rows into groups for a window function, or a table into partitions",
        "ROWS": "Window frame counted in physical rows; also ends FETCH … ROWS ONLY",
        "RANGE": "Window frame measured by the ORDER BY value",
        "UNBOUNDED": "A frame edge at the start or end of the partition",
        "CURRENT ROW": "A frame edge at the current row",
        // Definitions
        "CREATE": "Defines a new table, view, index or other object",
        "ALTER": "Changes the definition of an existing object",
        "DROP": "Deletes an object and its data",
        "PRIMARY KEY": "Column(s) that uniquely identify each row; implies NOT NULL",
        "FOREIGN KEY": "Column(s) that must match a key in another table",
        "REFERENCES": "Names the table and column a foreign key points to",
        "UNIQUE": "Disallows duplicate values",
        "CHECK": "A condition every row must satisfy",
        "CONSTRAINT": "Names a constraint",
        "INDEX": "A lookup structure that speeds up searches",
        "IF EXISTS": "Skips the command without error when the object is missing",
        "IF NOT EXISTS": "Skips the command without error when the object already exists",
        "CASCADE": "Also applies the change to dependent rows or objects",
        "RESTRICT": "Refuses the change while dependent rows or objects exist",
        // Transactions
        "BEGIN": "Starts a transaction",
        "COMMIT": "Makes the transaction's changes permanent",
        "ROLLBACK": "Undoes the transaction's changes",
        "EXPLAIN": "Shows how the database plans to run a statement",
    ]

    /// Single words the as-you-type rewriter may re-case (spec 5.4). Covers every word of the completion keyword
    /// lists, statement starts, table options and the dialects' type names, except `identifierLikeTypeWords`.
    /// ROLE, LEVEL, WORK and ZONE are left out on purpose: no list offers them alone, and re-casing a table
    /// named `role` breaks it on MySQL servers with case-sensitive table names.
    static let masterKeywordSet: Set<String> = [
        // Querying
        "SELECT", "FROM", "WHERE", "AS", "DISTINCT", "ALL", "WITH", "RECURSIVE", "VALUES", "INTO", "GROUP", "BY", "HAVING",
        "ORDER", "ASC", "DESC", "NULLS", "FIRST", "LAST", "LIMIT", "OFFSET", "FETCH", "NEXT", "ROWS", "ROW", "ONLY",
        "WINDOW", "QUALIFY",
        // Joins
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "ON", "USING", "LATERAL", "STRAIGHT_JOIN",
        // Set operations
        "UNION", "INTERSECT", "EXCEPT",
        // Data changes
        "INSERT", "UPDATE", "DELETE", "SET", "REPLACE", "MERGE", "UPSERT", "MATCHED", "RETURNING", "CONFLICT", "DO",
        "NOTHING", "DUPLICATE", "KEY", "IGNORE", "EXCLUDED", "DEFAULT",
        // Definitions
        "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "TABLE", "VIEW", "INDEX", "UNIQUE", "PRIMARY", "FOREIGN",
        "REFERENCES", "CONSTRAINT", "CHECK", "COLUMN", "ADD", "MODIFY", "CHANGE", "SCHEMA", "DATABASE", "SEQUENCE",
        "TRIGGER", "FUNCTION", "PROCEDURE", "EXTENSION", "TEMPORARY", "TEMP", "MATERIALIZED", "CASCADE", "RESTRICT",
        "IF", "EXISTS", "AUTO_INCREMENT", "SERIAL", "ENGINE", "CHARSET", "CHARACTER", "COLLATE", "COMMENT", "TABLESPACE",
        "CONCURRENTLY", "AFTER", "BEFORE", "NO", "ACTION", "BTREE", "HASH", "GIN", "GIST", "INHERITS", "PARTITION",
        "WITHOUT", "OIDS", "ROWID", "STRICT", "ROW_FORMAT",
        // Types
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
        "PRECISION", "VARCHAR", "CHAR", "VARYING", "TEXT", "BOOLEAN", "BOOL", "DATE", "TIME", "DATETIME", "TIMESTAMP",
        "INTERVAL", "BLOB", "JSON", "JSONB", "UUID", "BYTEA", "SIGNED", "UNSIGNED",
        "INT2", "INT4", "INT8", "FLOAT4", "FLOAT8", "HUGEINT", "UHUGEINT", "UBIGINT", "UINTEGER", "USMALLINT", "UTINYINT",
        "SMALLSERIAL", "BIGSERIAL", "SERIAL2", "SERIAL4", "SERIAL8", "BIT", "VARBIT", "BINARY", "VARBINARY",
        "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT", "CLOB", "NCHAR", "NVARCHAR", "BPCHAR",
        "BIG", "NATIVE", "ENUM", "STRUCT", "TIMESTAMPTZ", "TIMETZ", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS",
        "JSONPATH", "TSVECTOR", "TSQUERY", "INET", "CIDR", "MACADDR", "MACADDR8", "LSEG",
        "INT4RANGE", "INT8RANGE", "NUMRANGE", "TSRANGE", "TSTZRANGE", "DATERANGE", "INT4MULTIRANGE", "INT8MULTIRANGE",
        "NUMMULTIRANGE", "TSMULTIRANGE", "TSTZMULTIRANGE", "DATEMULTIRANGE", "REGCLASS", "REGCOLLATION", "REGCONFIG",
        "REGDICTIONARY", "REGNAMESPACE", "REGOPER", "REGOPERATOR", "REGPROC", "REGPROCEDURE", "REGROLE", "REGTYPE",
        "PG_LSN", "PG_SNAPSHOT", "TXID_SNAPSHOT", "REFCURSOR",
        // Conditionals
        "CASE", "WHEN", "THEN", "ELSE", "END",
        // Comparison and logic
        "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "BETWEEN", "SYMMETRIC", "TRUE", "FALSE", "UNKNOWN",
        "ANY", "SOME", "REGEXP", "RLIKE", "SIMILAR", "TO", "ESCAPE",
        // Transactions
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "START", "TRANSACTION", "ISOLATION",
        "READ", "WRITE", "COMMITTED", "UNCOMMITTED", "REPEATABLE", "SERIALIZABLE", "LOCK", "UNLOCK",
        // Windows
        "OVER", "RANGE", "GROUPS", "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT", "EXCLUDE", "FILTER",
        // MySQL index hints
        "FORCE", "USE",
        // Access control
        "GRANT", "REVOKE", "PRIVILEGES",
        // Utility
        "SHOW", "DESCRIBE", "EXPLAIN", "ANALYZE", "VACUUM", "CALL", "EXECUTE", "PREPARE", "DEALLOCATE", "COPY", "PRAGMA",
        "ATTACH", "DETACH",
    ]

    /// Type words (or words of multi-word types) that commonly name tables and columns, so the rewriter leaves
    /// them alone even though CREATE TABLE offers them as types.
    static let identifierLikeTypeWords: Set<String> = [
        "NAME", "PATH", "LINE", "POINT", "BOX", "CIRCLE", "POLYGON", "GEOMETRY", "YEAR", "MAP", "LIST", "STRING", "XML",
        "OID", "MONEY", "ZONE",
    ]

    /// Words each engine refuses as a bare table or column name, so completion quotes them on insert (spec A.2).
    /// PostgreSQL: pg_get_keywords() categories R and T (18). DuckDB: duckdb_keywords() categories reserved and
    /// type_function (1.5). SQLite: the keywords its parser rejects as names, plus CURRENT_DATE/TIME/TIMESTAMP, which
    /// silently shadow a column of that name. MySQL and MariaDB share a family, so their lists are merged; quoting a
    /// word one of them would accept is harmless.
    static let mysqlReservedWords = mysqlCatalogueReservedWords
        .union(mysqlUnlistedReservedWords)
        .union(mariadbReservedWords)

    /// information_schema.KEYWORDS with RESERVED = 1 (MySQL 8.4).
    static let mysqlCatalogueReservedWords = words("""
        ACCESSIBLE ADD ALL ALTER ANALYZE AND AS ASC ASENSITIVE BEFORE BETWEEN BIGINT BINARY BLOB BOTH BY CALL CASCADE
        CASE CHANGE CHAR CHARACTER CHECK COLLATE COLUMN CONDITION CONSTRAINT CONTINUE CONVERT CREATE CROSS CUME_DIST
        CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR DATABASE DATABASES DAY_HOUR DAY_MICROSECOND
        DAY_MINUTE DAY_SECOND DEC DECIMAL DECLARE DEFAULT DELAYED DELETE DENSE_RANK DESC DESCRIBE DETERMINISTIC
        DISTINCT DISTINCTROW DIV DOUBLE DROP DUAL EACH ELSE ELSEIF EMPTY ENCLOSED ESCAPED EXCEPT EXISTS EXIT EXPLAIN
        FALSE FETCH FIRST_VALUE FLOAT FLOAT4 FLOAT8 FOR FORCE FOREIGN FROM FULLTEXT FUNCTION GENERATED GET GRANT GROUP
        GROUPING GROUPS HAVING HIGH_PRIORITY HOUR_MICROSECOND HOUR_MINUTE HOUR_SECOND IF IGNORE IN INDEX INFILE INNER
        INOUT INSENSITIVE INSERT INT INT1 INT2 INT3 INT4 INT8 INTEGER INTERSECT INTERVAL INTO IO_AFTER_GTIDS
        IO_BEFORE_GTIDS IS ITERATE JOIN JSON_TABLE KEY KEYS KILL LAG LAST_VALUE LATERAL LEAD LEADING LEAVE LEFT LIKE
        LIMIT LINEAR LINES LOAD LOCALTIME LOCALTIMESTAMP LOCK LONG LONGBLOB LONGTEXT LOOP LOW_PRIORITY MATCH MAXVALUE
        MEDIUMBLOB MEDIUMINT MEDIUMTEXT MIDDLEINT MINUTE_MICROSECOND MINUTE_SECOND MOD MODIFIES NATURAL NOT
        NO_WRITE_TO_BINLOG NTH_VALUE NTILE NULL NUMERIC OF ON OPTIMIZE OPTIMIZER_COSTS OPTION OPTIONALLY OR ORDER OUT
        OUTER OUTFILE OVER PARTITION PERCENT_RANK PRECISION PRIMARY PROCEDURE PURGE RANGE RANK READ READS READ_WRITE
        REAL RECURSIVE REFERENCES REGEXP RELEASE RENAME REPEAT REPLACE REQUIRE RESIGNAL RESTRICT RETURN REVOKE RIGHT
        RLIKE ROW ROWS ROW_NUMBER SCHEMA SCHEMAS SECOND_MICROSECOND SELECT SENSITIVE SEPARATOR SET SHOW SIGNAL
        SMALLINT SPATIAL SPECIFIC SQL SQLEXCEPTION SQLSTATE SQLWARNING SQL_BIG_RESULT SQL_CALC_FOUND_ROWS
        SQL_SMALL_RESULT SSL STARTING STORED STRAIGHT_JOIN SYSTEM TABLE TERMINATED THEN TINYBLOB TINYINT TINYTEXT TO
        TRAILING TRIGGER TRUE UNDO UNION UNIQUE UNLOCK UNSIGNED UPDATE USAGE USE USING UTC_DATE UTC_TIME UTC_TIMESTAMP
        VALUES VARBINARY VARCHAR VARCHARACTER VARYING VIRTUAL WHEN WHERE WHILE WINDOW WITH WRITE XOR YEAR_MONTH
        ZEROFILL
        """)

    /// MySQL 8.4 marks these RESERVED = 0, yet its parser rejects them as bare names; SQL_NO_CACHE and
    /// SQL_BUFFER_RESULT only as the first item of a SELECT list, where they read as modifiers.
    static let mysqlUnlistedReservedWords = words("""
        CUBE MANUAL PARALLEL QUALIFY SQL_BUFFER_RESULT SQL_NO_CACHE TABLESAMPLE
        """)

    /// Reserved in MariaDB (its "Reserved Words" documentation, up to 12.3) but not in MySQL 8.4.
    static let mariadbReservedWords = words("""
        CONVERSION CURRENT_PATH CURRENT_ROLE DELETE_DOMAIN_ID DO_DOMAIN_IDS IGNORE_DOMAIN_IDS MASTER_DEMOTE_TO_REPLICA
        MASTER_DEMOTE_TO_SLAVE MASTER_SSL_VERIFY_SERVER_CERT OFFSET PAGE_CHECKSUM PARSE_VCOL_EXPR PORTION REF_SYSTEM_ID
        RETURNING SQL_AFTER_GTIDS SQL_BEFORE_GTIDS STATS_AUTO_RECALC STATS_PERSISTENT STATS_SAMPLE_PAGES TO_DATE VECTOR
        """)

    static let postgresqlReservedWords = words("""
        ALL ANALYSE ANALYZE AND ANY ARRAY AS ASC ASYMMETRIC AUTHORIZATION BINARY BOTH CASE CAST CHECK COLLATE
        COLLATION COLUMN CONCURRENTLY CONSTRAINT CREATE CROSS CURRENT_CATALOG CURRENT_DATE CURRENT_ROLE CURRENT_SCHEMA
        CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER DEFAULT DEFERRABLE DESC DISTINCT DO ELSE END EXCEPT FALSE FETCH
        FOR FOREIGN FREEZE FROM FULL GRANT GROUP HAVING ILIKE IN INITIALLY INNER INTERSECT INTO IS ISNULL JOIN LATERAL
        LEADING LEFT LIKE LIMIT LOCALTIME LOCALTIMESTAMP NATURAL NOT NOTNULL NULL OFFSET ON ONLY OR ORDER OUTER
        OVERLAPS PLACING PRIMARY REFERENCES RETURNING RIGHT SELECT SESSION_USER SIMILAR SOME SYMMETRIC SYSTEM_USER
        TABLE TABLESAMPLE THEN TO TRAILING TRUE UNION UNIQUE USER USING VARIADIC VERBOSE WHEN WHERE WINDOW WITH
        """)

    static let sqliteReservedWords = words("""
        ADD ALL ALTER AND AS AUTOINCREMENT BETWEEN CASE CAST CHECK COLLATE COMMIT CONSTRAINT CREATE CURRENT_DATE
        CURRENT_TIME CURRENT_TIMESTAMP DEFAULT DEFERRABLE DELETE DISTINCT DROP ELSE ESCAPE EXCEPT EXISTS FOREIGN FROM
        GROUP HAVING IF IN INDEX INSERT INTERSECT INTO IS ISNULL JOIN LIMIT NOT NOTHING NOTNULL NULL ON OR ORDER
        PRIMARY RAISE REFERENCES RETURNING SELECT SET TABLE THEN TO TRANSACTION UNION UNIQUE UPDATE USING VALUES WHEN
        WHERE
        """)

    static let duckdbReservedWords = words("""
        ALL ANALYSE ANALYZE AND ANTI ANY ARRAY AS ASC ASOF ASYMMETRIC AT AUTHORIZATION BINARY BOTH BY CASE CAST CHECK
        COLLATE COLLATION COLUMN COLUMNS CONCURRENTLY CONSTRAINT CREATE CROSS DEFAULT DEFERRABLE DESC DESCRIBE
        DISTINCT DO ELSE END EXCEPT FALSE FETCH FOR FOREIGN FREEZE FROM FULL GENERATED GLOB GROUP HAVING ILIKE IN
        INITIALLY INNER INTERSECT INTO IS ISNULL JOIN LAMBDA LATERAL LEADING LEFT LIKE LIMIT MAP NATURAL NOT NOTNULL
        NULL OFFSET ON ONLY OR ORDER OUTER OVERLAPS PIVOT PIVOT_LONGER PIVOT_WIDER PLACING POSITIONAL PRIMARY QUALIFY
        REFERENCES RETURNING RIGHT SELECT SEMI SHOW SIMILAR SOME STRUCT SUMMARIZE SYMMETRIC TABLE TABLESAMPLE THEN TO
        TRAILING TRUE TRY_CAST UNION UNIQUE UNPACK UNPIVOT USING VARIADIC VERBOSE WHEN WHERE WINDOW WITH
        """)

    /// Without a dialect only words that no engine accepts bare.
    static let commonReservedWords = mysqlReservedWords
        .intersection(postgresqlReservedWords)
        .intersection(sqliteReservedWords)
        .intersection(duckdbReservedWords)

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
