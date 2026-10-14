import Foundation

// The generic function catalogue (spec 6.3). It is a union across engines, so a few entries only exist in some.

extension SQLCompletionVocabulary {
    /// The catalogue in its groups, in generation order.
    static let genericFunctionGroups: [(name: String, functions: [SQLFunctionEntry])] = [
        ("Aggregate", aggregateFunctions),
        ("Date/time", dateTimeFunctions),
        ("String", stringFunctions),
        ("Numeric", numericFunctions),
        ("Null handling", nullHandlingFunctions),
        ("Conversion", conversionFunctions),
        ("Window", windowFunctions),
        ("JSON", jsonFunctions),
        ("Session", sessionFunctions),
    ]

    static let genericCatalogue: [SQLFunctionEntry] = genericFunctionGroups.flatMap(\.functions)

    private static func function(_ signature: String, _ summary: String) -> SQLFunctionEntry {
        let name = String(signature.prefix { $0 != "(" })
        return SQLFunctionEntry(name: name, signature: signature, summary: summary)
    }

    /// SQL-standard functions written without parentheses.
    private static func niladic(_ name: String, _ summary: String) -> SQLFunctionEntry {
        SQLFunctionEntry(name: name, signature: name, summary: summary, isNiladic: true)
    }

    static let aggregateFunctions: [SQLFunctionEntry] = [
        function("COUNT(expr)", "Counts rows, or the non-null values of expr"),
        function("SUM(expr)", "Total of the non-null values"),
        function("AVG(expr)", "Arithmetic mean of the non-null values"),
        function("MIN(expr)", "Smallest value in the group"),
        function("MAX(expr)", "Largest value in the group"),
        function("GROUP_CONCAT(expr [ORDER BY …] [SEPARATOR sep])", "Joins the group's values into one string (MySQL, SQLite)"),
        function("STRING_AGG(expr, delimiter)", "Joins the group's values into one string with a delimiter"),
        function("ARRAY_AGG(expr)", "Collects the group's values into an array"),
        function("STDDEV(expr)", "Standard deviation of the values"),
        function("VARIANCE(expr)", "Variance of the values"),
        function("BIT_AND(expr)", "Bitwise AND across the group"),
        function("BIT_OR(expr)", "Bitwise OR across the group"),
        function("JSON_OBJECTAGG(key, value)", "Builds one JSON object from the group's key/value pairs"),
        function("JSON_ARRAYAGG(expr)", "Builds one JSON array from the group's values"),
    ]

    static let dateTimeFunctions: [SQLFunctionEntry] = [
        function("NOW()", "Current date and time"),
        niladic("CURRENT_TIMESTAMP", "Date and time when the statement (or transaction) started"),
        niladic("CURRENT_DATE", "Today's date"),
        niladic("CURRENT_TIME", "Current time of day"),
        niladic("LOCALTIME", "Current time of day, without time zone"),
        niladic("LOCALTIMESTAMP", "Current date and time, without time zone"),
        function("CURDATE()", "Today's date (MySQL)"),
        function("CURTIME()", "Current time of day (MySQL)"),
        function("SYSDATE()", "Time at which the call runs, not when the statement began (MySQL)"),
        function("DATE(expr)", "Date part of a date/time value"),
        function("TIME(expr)", "Time part of a date/time value"),
        function("YEAR(date)", "Year of a date"),
        function("MONTH(date)", "Month number, 1 to 12"),
        function("DAY(date)", "Day of the month"),
        function("HOUR(time)", "Hour, 0 to 23"),
        function("MINUTE(time)", "Minute, 0 to 59"),
        function("SECOND(time)", "Second, 0 to 59"),
        function("DAYOFWEEK(date)", "Weekday number: 1 is Sunday in MySQL, 0 is Sunday in DuckDB"),
        function("DAYOFYEAR(date)", "Day of the year, 1 to 366"),
        function("WEEK(date[, mode])", "Week number within the year"),
        function("QUARTER(date)", "Quarter of the year, 1 to 4"),
        function("DAYNAME(date)", "Weekday name"),
        function("MONTHNAME(date)", "Month name"),
        function("LAST_DAY(date)", "Last day of the date's month"),
        function("DATE_ADD(date, INTERVAL expr unit)", "Date moved forward by an interval"),
        function("DATE_SUB(date, INTERVAL expr unit)", "Date moved back by an interval"),
        function("DATEDIFF(end, start)", "Whole days between two dates (MySQL; DuckDB takes a unit first)"),
        function("TIMESTAMPDIFF(unit, start, end)", "Distance between two date/times, counted in unit"),
        function("TIMESTAMPADD(unit, count, datetime)", "Date/time moved by count units"),
        function("DATE_FORMAT(date, format)", "Date rendered as text using % specifiers"),
        function("STR_TO_DATE(text, format)", "Text parsed into a date/time using % specifiers"),
        function("EXTRACT(field FROM source)", "One field (YEAR, MONTH, DAY, …) of a date/time"),
        function("DATE_TRUNC(field, source)", "Timestamp cut down to the given precision"),
        function("DATE_PART(field, source)", "Numeric value of one field of a date/time"),
        function("AGE(timestamp[, timestamp])", "Interval between two timestamps, or from one up to today"),
        function("TO_TIMESTAMP(text, format)", "Timestamp parsed from text, or from Unix epoch seconds"),
        function("TO_DATE(text, format)", "Date parsed from text with a format"),
        function("TO_CHAR(value, format)", "Number or date/time rendered as text with a format"),
        function("UNIX_TIMESTAMP([datetime])", "Seconds since 1970-01-01 UTC"),
        function("FROM_UNIXTIME(seconds[, format])", "Date/time for a count of Unix epoch seconds"),
    ]

    static let stringFunctions: [SQLFunctionEntry] = [
        function("CONCAT(text, …)", "Strings glued together"),
        function("CONCAT_WS(separator, text, …)", "Strings joined with a separator; NULLs are skipped"),
        function("SUBSTRING(text, start[, length])", "Part of a string from a 1-based position"),
        function("SUBSTR(text, start[, length])", "Short form of SUBSTRING"),
        function("LENGTH(text)", "String length (bytes in MySQL, characters elsewhere)"),
        function("CHAR_LENGTH(text)", "Number of characters"),
        function("OCTET_LENGTH(text)", "Number of bytes"),
        function("UPPER(text)", "Text in uppercase"),
        function("LOWER(text)", "Text in lowercase"),
        function("INITCAP(text)", "Each word with a capital first letter"),
        function("TRIM([BOTH|LEADING|TRAILING] [chars FROM] text)", "Text without surrounding spaces or the given characters"),
        function("LTRIM(text)", "Text without leading spaces"),
        function("RTRIM(text)", "Text without trailing spaces"),
        function("REPLACE(text, from, to)", "Every occurrence of one substring swapped for another"),
        function("TRANSLATE(text, from, to)", "Characters swapped one for one"),
        function("LPAD(text, length, fill)", "Text padded on the left to a length"),
        function("RPAD(text, length, fill)", "Text padded on the right to a length"),
        function("LEFT(text, n)", "First n characters"),
        function("RIGHT(text, n)", "Last n characters"),
        function("REVERSE(text)", "Characters in reverse order"),
        function("REPEAT(text, n)", "Text repeated n times"),
        function("SPACE(n)", "A string of n spaces"),
        function("INSTR(text, substring)", "1-based position of a substring, 0 when absent"),
        function("LOCATE(substring, text[, start])", "1-based position of a substring, searching from start"),
        function("POSITION(substring IN text)", "1-based position of a substring"),
        function("STRPOS(text, substring)", "1-based position of a substring"),
        function("ASCII(text)", "Numeric code of the first character"),
        function("CHR(code)", "Character for a numeric code"),
        function("FORMAT(value, …)", "Formatted text: grouped number in MySQL, printf-style template elsewhere"),
        function("MD5(text)", "MD5 digest as hex"),
        function("SHA1(text)", "SHA-1 digest as hex"),
        function("SHA2(text, bits)", "SHA-2 digest (224, 256, 384 or 512 bits) as hex"),
        function("REGEXP_REPLACE(text, pattern, replacement)", "Regular-expression matches replaced"),
        function("REGEXP_SUBSTR(text, pattern)", "Part of the text matching a regular expression"),
        function("SPLIT_PART(text, delimiter, n)", "The nth piece after splitting on a delimiter"),
    ]

    static let numericFunctions: [SQLFunctionEntry] = [
        function("ABS(x)", "Absolute value"),
        function("ROUND(x[, decimals])", "x rounded to a number of decimals (0 by default)"),
        function("FLOOR(x)", "Largest integer not greater than x"),
        function("CEIL(x)", "Smallest integer not less than x"),
        function("CEILING(x)", "Same as CEIL"),
        function("TRUNCATE(x, decimals)", "x cut to a number of decimals without rounding (MySQL)"),
        function("TRUNC(x[, decimals])", "x cut to a number of decimals without rounding"),
        function("MOD(x, y)", "Remainder of x divided by y"),
        function("POWER(x, y)", "x to the power y"),
        function("POW(x, y)", "Same as POWER"),
        function("SQRT(x)", "Square root"),
        function("EXP(x)", "e to the power x"),
        function("LN(x)", "Natural logarithm"),
        function("LOG([base,] x)", "Logarithm; with one argument natural in MySQL, base 10 elsewhere"),
        function("LOG10(x)", "Base-10 logarithm"),
        function("RAND([seed])", "Random number from 0 up to 1 (MySQL)"),
        function("SIGN(x)", "-1, 0 or 1 depending on the sign of x"),
        function("GREATEST(value, …)", "Largest argument"),
        function("LEAST(value, …)", "Smallest argument"),
        function("PI()", "The constant pi"),
        function("SIN(x)", "Sine of an angle in radians"),
        function("COS(x)", "Cosine of an angle in radians"),
        function("TAN(x)", "Tangent of an angle in radians"),
        function("COT(x)", "Cotangent of an angle in radians"),
        function("ASIN(x)", "Arc sine, in radians"),
        function("ACOS(x)", "Arc cosine, in radians"),
        function("ATAN(x)", "Arc tangent, in radians"),
        function("ATAN2(y, x)", "Arc tangent of y/x using both signs, in radians"),
        function("DEGREES(radians)", "Radians converted to degrees"),
        function("RADIANS(degrees)", "Degrees converted to radians"),
    ]

    static let nullHandlingFunctions: [SQLFunctionEntry] = [
        function("COALESCE(value, …)", "First argument that is not NULL"),
        function("IFNULL(expr, fallback)", "fallback when expr is NULL (MySQL, SQLite)"),
        function("NULLIF(a, b)", "NULL when a equals b, otherwise a"),
        function("NVL(expr, fallback)", "fallback when expr is NULL (MariaDB, Oracle)"),
        function("ISNULL(expr)", "1 when expr is NULL, else 0 (MySQL)"),
    ]

    static let conversionFunctions: [SQLFunctionEntry] = [
        function("CAST(expr AS type)", "Value converted to another type"),
        function("CONVERT(expr, type)", "Value converted to a type or character set (MySQL)"),
        function("BINARY(expr)", "String treated as bytes, so comparisons are byte by byte (MySQL; deprecated)"),
    ]

    static let windowFunctions: [SQLFunctionEntry] = [
        function("ROW_NUMBER() OVER (…)", "Running number of the row within its partition"),
        function("RANK() OVER (…)", "Rank within the partition; ties leave gaps"),
        function("DENSE_RANK() OVER (…)", "Rank within the partition; ties leave no gaps"),
        function("NTILE(buckets) OVER (…)", "Bucket number when the partition is split into equal groups"),
        function("LAG(expr[, offset[, default]]) OVER (…)", "Value from a row before this one"),
        function("LEAD(expr[, offset[, default]]) OVER (…)", "Value from a row after this one"),
        function("FIRST_VALUE(expr) OVER (…)", "Value at the first row of the window frame"),
        function("LAST_VALUE(expr) OVER (…)", "Value at the last row of the window frame"),
        function("NTH_VALUE(expr, n) OVER (…)", "Value at the nth row of the window frame"),
        function("PERCENT_RANK() OVER (…)", "Relative rank between 0 and 1"),
        function("CUME_DIST() OVER (…)", "Share of partition rows up to and including this one"),
    ]

    static let jsonFunctions: [SQLFunctionEntry] = [
        function("JSON_EXTRACT(json, path, …)", "Value found at a JSON path (MySQL, SQLite, DuckDB)"),
        function("JSON_UNQUOTE(json)", "JSON string value without its quotes (MySQL)"),
        function("JSON_OBJECT(key, value, …)", "JSON object built from key/value pairs"),
        function("JSON_ARRAY(value, …)", "JSON array built from the arguments"),
        function("JSON_SET(json, path, value, …)", "Document with values inserted or replaced at paths"),
        function("JSON_INSERT(json, path, value, …)", "Document with values added only where paths are missing"),
        function("JSON_REPLACE(json, path, value, …)", "Document with values replaced only where paths exist"),
        function("JSON_REMOVE(json, path, …)", "Document with the values at paths deleted"),
        function("JSON_CONTAINS(target, candidate[, path])", "Whether one JSON document includes another"),
        function("JSON_KEYS(json[, path])", "Keys of a JSON object, as an array"),
        function("JSON_LENGTH(json[, path])", "Number of elements or keys (MySQL)"),
        function("JSON_VALID(value)", "Whether the value is well-formed JSON"),
        function("JSON_TYPE(json)", "Kind of a JSON value (object, array, string, …)"),
        function("JSON_BUILD_OBJECT(key, value, …)", "JSON object from alternating keys and values (PostgreSQL)"),
        function("JSON_BUILD_ARRAY(value, …)", "JSON array from the arguments (PostgreSQL)"),
        function("JSON_AGG(expr)", "Group's values gathered into a JSON array (PostgreSQL)"),
        function("JSONB_AGG(expr)", "Group's values gathered into a jsonb array (PostgreSQL)"),
        function("JSONB_SET(target, path, value[, create_missing])", "jsonb with the value at a path replaced (PostgreSQL)"),
        function("ROW_TO_JSON(record)", "A row as a JSON object (PostgreSQL)"),
        function("TO_JSON(value)", "Any value converted to JSON"),
    ]

    /// SQL-standard session values, written without parentheses (MySQL needs them on two; see `functions(_:)`).
    static let sessionFunctions: [SQLFunctionEntry] = [
        niladic("CURRENT_USER", "Role or account whose privileges apply"),
        niladic("SESSION_USER", "User that opened the session"),
        niladic("USER", "Current user; in MySQL the account the client connected as"),
    ]
}

// Dialect extras (spec 6.3, 6.6). One function per line, parsed by `parseFunctionTable`. Names were checked
// against the engines' own catalogues (MySQL 8.4 help topics, PostgreSQL 18 pg_proc, the SQLite library macOS
// ships, DuckDB 1.5 duckdb_functions()); a few are SQL syntax forms that those catalogues do not list.

extension SQLCompletionVocabulary {
    static let mysqlFunctionTable = """
        ADDDATE(date, INTERVAL expr unit) | Same as DATE_ADD
        ADDTIME(datetime, time) | Date/time with a time span added
        AES_DECRYPT(ciphertext, key) | Decrypts AES-encrypted bytes
        AES_ENCRYPT(text, key) | Encrypts with AES
        ANY_VALUE(expr) | Any value of the group, silencing ONLY_FULL_GROUP_BY
        BENCHMARK(count, expr) | Runs expr count times, for timing
        BIN(n) | Binary digits of a number
        BIN_TO_UUID(bytes[, swap]) | UUID text from its 16-byte form
        BIT_COUNT(n) | Number of set bits
        BIT_LENGTH(text) | Length in bits
        BIT_XOR(expr) | Bitwise XOR across the group
        CHAR(code, … [USING charset]) | Characters for numeric codes
        CHARACTER_LENGTH(text) | Number of characters
        CHARSET(text) | Character set of the argument
        COLLATION(text) | Collation of the argument
        COMPRESS(text) | zlib-compressed bytes
        CONNECTION_ID() | Thread id of this connection
        CONV(n, from_base, to_base) | Number converted between bases
        CONVERT_TZ(datetime, from_tz, to_tz) | Date/time moved between time zones
        CRC32(text) | CRC-32 checksum
        CURRENT_ROLE() | Roles active in this session
        DATABASE() | Name of the default database
        DAYOFMONTH(date) | Day of the month
        ELT(n, text1, text2, …) | The nth argument after n
        FIELD(value, value1, value2, …) | 1-based index of value in the list, 0 if absent
        FIND_IN_SET(text, list) | 1-based index of text in a comma-separated list
        FORMAT_BYTES(count) | Byte count in human units
        FROM_BASE64(text) | Decodes base64
        FROM_DAYS(n) | Date for a day number
        GET_LOCK(name, timeout) | Takes a named user lock
        GROUPING(expr, …) | Whether a ROLLUP row aggregates over expr
        HEX(value) | Hexadecimal text of a number or string
        IF(condition, then, else) | then when condition is true, else otherwise
        INET6_ATON(address) | IPv4/IPv6 address as bytes
        INET6_NTOA(bytes) | Bytes as an IPv4/IPv6 address
        INET_ATON(address) | IPv4 address as a number
        INET_NTOA(n) | Number as an IPv4 address
        IS_FREE_LOCK(name) | Whether a named lock is free
        IS_IPV4(text) | Whether text is an IPv4 address
        IS_IPV6(text) | Whether text is an IPv6 address
        IS_UUID(text) | Whether text is a valid UUID
        JSON_ARRAY_APPEND(json, path, value, …) | Values appended to arrays at paths
        JSON_ARRAY_INSERT(json, path, value, …) | Values inserted into arrays at positions
        JSON_CONTAINS_PATH(json, 'one'|'all', path, …) | Whether the document has data at the paths
        JSON_DEPTH(json) | Maximum nesting depth
        JSON_MERGE_PATCH(json, json, …) | Documents merged; later keys replace earlier ones
        JSON_MERGE_PRESERVE(json, json, …) | Documents merged; duplicate keys become arrays
        JSON_OVERLAPS(json1, json2) | Whether two documents share a key/value or element
        JSON_PRETTY(json) | Indented JSON text
        JSON_QUOTE(text) | Text as a JSON string literal
        JSON_SCHEMA_VALID(schema, document) | Whether a document matches a JSON schema
        JSON_SEARCH(json, 'one'|'all', text[, escape[, path]]) | Path to a matching string
        JSON_STORAGE_SIZE(json) | Bytes used to store the document
        JSON_TABLE(json, path COLUMNS (…)) AS alias | JSON data as relational rows
        JSON_VALUE(json, path [RETURNING type]) | Scalar at a path, optionally typed
        LAST_INSERT_ID([expr]) | Last AUTO_INCREMENT value generated here
        LCASE(text) | Same as LOWER
        MAKEDATE(year, day_of_year) | Date from a year and day number
        MAKETIME(hour, minute, second) | Time from parts
        MAKE_SET(bits, text1, text2, …) | Comma list of the arguments selected by bits
        MATCH(column, …) AGAINST (expr [mode]) | FULLTEXT relevance search
        MICROSECOND(time) | Microseconds part
        MID(text, start, length) | Same as SUBSTRING
        OCT(n) | Octal digits of a number
        ORD(text) | Code of the leftmost (multibyte) character
        PERIOD_ADD(period, months) | YYYYMM period moved by months
        PERIOD_DIFF(period1, period2) | Months between two YYYYMM periods
        QUOTE(text) | Text escaped as an SQL string literal
        RANDOM_BYTES(length) | Cryptographically random bytes
        REGEXP_INSTR(text, pattern) | Position of a regular-expression match
        REGEXP_LIKE(text, pattern[, match_type]) | Whether a regular expression matches
        RELEASE_LOCK(name) | Releases a named user lock
        ROW_COUNT() | Rows changed by the previous statement
        SCHEMA() | Same as DATABASE()
        SEC_TO_TIME(seconds) | Seconds as a time value
        SLEEP(seconds) | Pauses, then returns 0
        SOUNDEX(text) | Phonetic key
        STD(expr) | Population standard deviation
        STDDEV_POP(expr) | Population standard deviation
        STDDEV_SAMP(expr) | Sample standard deviation
        STRCMP(a, b) | -1, 0 or 1 comparing two strings
        ST_ASGEOJSON(geometry) | Geometry as GeoJSON
        ST_ASTEXT(geometry) | Geometry as WKT text
        ST_CONTAINS(g1, g2) | Whether g1 contains g2
        ST_DISTANCE(g1, g2[, unit]) | Distance between geometries
        ST_DISTANCE_SPHERE(p1, p2[, radius]) | Distance on a sphere, in meters
        ST_GEOMFROMGEOJSON(text) | Geometry from GeoJSON
        ST_GEOMFROMTEXT(wkt[, srid]) | Geometry from WKT text
        ST_INTERSECTS(g1, g2) | Whether two geometries intersect
        ST_WITHIN(g1, g2) | Whether g1 is inside g2
        ST_X(point) | X coordinate
        ST_Y(point) | Y coordinate
        SUBDATE(date, INTERVAL expr unit) | Same as DATE_SUB
        SUBSTRING_INDEX(text, delimiter, count) | Text before (or after) the countth delimiter
        SUBTIME(datetime, time) | Date/time with a time span subtracted
        SYSTEM_USER() | Same as USER()
        TIMEDIFF(a, b) | a minus b as a time
        TIME_FORMAT(time, format) | Time rendered with % specifiers
        TIME_TO_SEC(time) | Time as seconds
        TO_BASE64(text) | Encodes base64
        TO_DAYS(date) | Day number since year 0
        TO_SECONDS(datetime) | Seconds since year 0
        UCASE(text) | Same as UPPER
        UNCOMPRESS(bytes) | Reverses COMPRESS
        UNHEX(text) | Bytes from hexadecimal text
        UTC_DATE() | Current UTC date
        UTC_TIME() | Current UTC time
        UTC_TIMESTAMP() | Current UTC date and time
        UUID() | New version-1 UUID
        UUID_SHORT() | Unique 64-bit integer
        UUID_TO_BIN(uuid[, swap]) | UUID text as 16 bytes
        VALIDATE_PASSWORD_STRENGTH(text) | Password strength score, 0 to 100
        VAR_POP(expr) | Population variance
        VAR_SAMP(expr) | Sample variance
        VERSION() | Server version
        WEEKDAY(date) | Weekday index where 0 is Monday
        WEEKOFYEAR(date) | Calendar week, 1 to 53
        YEARWEEK(date[, mode]) | Year and week as YYYYWW
        """

    static let postgresqlFunctionTable = """
        # Aggregate
        any_value(expr) | Any non-null value of the group
        bit_xor(expr) | Bitwise XOR across the group
        bool_and(expr) | True when every value is true
        bool_or(expr) | True when any value is true
        corr(y, x) | Correlation coefficient
        covar_pop(y, x) | Population covariance
        covar_samp(y, x) | Sample covariance
        every(expr) | Same as bool_and
        json_agg_strict(expr) | Like json_agg, skipping NULLs
        json_object_agg(key, value) | Key/value pairs gathered into a JSON object
        jsonb_agg_strict(expr) | Like jsonb_agg, skipping NULLs
        jsonb_object_agg(key, value) | Key/value pairs gathered into a jsonb object
        mode() WITHIN GROUP (ORDER BY expr) | Most frequent value
        percentile_cont(fraction) WITHIN GROUP (ORDER BY expr) | Interpolated percentile
        percentile_disc(fraction) WITHIN GROUP (ORDER BY expr) | First value at or past the percentile
        range_agg(range) | Union of ranges, as a multirange
        range_intersect_agg(range) | Intersection of ranges
        regr_avgx(y, x) | Mean of x over rows where both are non-null
        regr_avgy(y, x) | Mean of y over rows where both are non-null
        regr_count(y, x) | Rows where both are non-null
        regr_intercept(y, x) | Intercept of the least-squares line
        regr_r2(y, x) | Coefficient of determination
        regr_slope(y, x) | Slope of the least-squares line
        regr_sxx(y, x) | Sum of squared deviations of x
        regr_sxy(y, x) | Sum of products of the x and y deviations
        regr_syy(y, x) | Sum of squared deviations of y
        stddev_pop(expr) | Population standard deviation
        stddev_samp(expr) | Sample standard deviation
        var_pop(expr) | Population variance
        var_samp(expr) | Sample variance
        xmlagg(xml) | XML values concatenated

        # String and binary
        bit_count(bytes) | Number of set bits
        bit_length(text) | Length in bits
        btrim(text[, characters]) | Characters trimmed from both ends
        casefold(text) | Text folded for caseless comparison
        character_length(text) | Number of characters
        convert_from(bytes, encoding) | Bytes in an encoding decoded to text
        convert_to(text, encoding) | Text encoded to bytes
        crc32(bytes) | CRC-32 checksum
        crc32c(bytes) | CRC-32C checksum
        decode(text, format) | Bytes from base64, escape or hex text
        encode(bytes, format) | Bytes as base64, escape or hex text
        get_bit(bytes, n) | One bit of a binary string
        get_byte(bytes, n) | One byte of a binary string
        normalize(text[, form]) | Unicode-normalized text (NFC by default)
        overlay(text PLACING replacement FROM start [FOR count]) | Part of a string replaced
        parse_ident(text) | Qualified identifier split into its parts
        quote_ident(text) | Text quoted as an identifier when needed
        quote_literal(value) | Value quoted as a string literal
        quote_nullable(value) | Like quote_literal, but NULL becomes the word NULL
        regexp_count(text, pattern) | Number of regular-expression matches
        regexp_instr(text, pattern) | Position of a regular-expression match
        regexp_like(text, pattern[, flags]) | Whether a regular expression matches
        regexp_match(text, pattern[, flags]) | Captured groups of the first match
        regexp_matches(text, pattern[, flags]) | Captured groups of each match (all with flag g)
        regexp_split_to_array(text, pattern) | Text split on a regular expression, as an array
        regexp_split_to_table(text, pattern) | Text split on a regular expression, as rows
        set_bit(bytes, n, bit) | Binary string with one bit changed
        set_byte(bytes, n, byte) | Binary string with one byte changed
        sha224(bytes) | SHA-224 digest
        sha256(bytes) | SHA-256 digest
        sha384(bytes) | SHA-384 digest
        sha512(bytes) | SHA-512 digest
        starts_with(text, prefix) | Whether text begins with prefix
        string_to_array(text, delimiter[, null_string]) | Text split into an array
        string_to_table(text, delimiter[, null_string]) | Text split into rows
        to_ascii(text[, encoding]) | Text with accents removed
        to_bin(n) | Binary digits of an integer
        to_hex(n) | Hexadecimal digits of an integer
        to_number(text, format) | Number parsed from text with a format
        to_oct(n) | Octal digits of an integer
        unistr(text) | Text with Unicode escapes decoded

        # Math
        acosd(x) | Arc cosine, in degrees
        acosh(x) | Inverse hyperbolic cosine
        asind(x) | Arc sine, in degrees
        asinh(x) | Inverse hyperbolic sine
        atan2d(y, x) | Arc tangent of y/x, in degrees
        atand(x) | Arc tangent, in degrees
        atanh(x) | Inverse hyperbolic tangent
        cbrt(x) | Cube root
        cosd(x) | Cosine of an angle in degrees
        cosh(x) | Hyperbolic cosine
        cotd(x) | Cotangent of an angle in degrees
        div(y, x) | Integer quotient of y/x
        erf(x) | Error function
        erfc(x) | Complementary error function
        factorial(n) | n!
        gamma(x) | Gamma function
        gcd(a, b) | Greatest common divisor
        lcm(a, b) | Least common multiple
        lgamma(x) | Natural log of the gamma function
        min_scale(numeric) | Fewest decimals that represent the value exactly
        random([min, max]) | Random number from 0 up to 1, or within [min, max]
        random_normal([mean, stddev]) | Normally distributed random number
        scale(numeric) | Number of decimal digits after the point
        setseed(seed) | Seeds random()
        sind(x) | Sine of an angle in degrees
        sinh(x) | Hyperbolic sine
        tand(x) | Tangent of an angle in degrees
        tanh(x) | Hyperbolic tangent
        trim_scale(numeric) | Value without trailing fractional zeros
        width_bucket(value, low, high, count) | Bucket of value in an equal-width histogram

        # Date/time
        clock_timestamp() | Actual current time; moves during a statement
        date_bin(stride, source, origin) | Timestamp floored into fixed-width bins
        date_subtract(timestamptz, interval[, zone]) | Interval subtracted in a time zone
        isfinite(value) | Whether a date, timestamp or interval is finite
        justify_days(interval) | 30-day spans folded into months
        justify_hours(interval) | 24-hour spans folded into days
        justify_interval(interval) | Both justify_days and justify_hours applied
        make_date(year, month, day) | Date from parts
        make_interval(years, months, weeks, days, hours, mins, secs) | Interval from parts
        make_time(hour, min, sec) | Time from parts
        make_timestamp(year, month, day, hour, min, sec) | Timestamp from parts
        make_timestamptz(year, month, day, hour, min, sec[, timezone]) | Timestamp with time zone from parts
        statement_timestamp() | Start time of the current statement
        timeofday() | Actual current time, as text
        timezone(zone, timestamp) | Timestamp converted to another time zone
        transaction_timestamp() | Start time of the current transaction

        # JSON
        array_to_json(array[, pretty]) | Array as a JSON array
        json_array_elements(json) | Top-level array elements as rows
        json_array_elements_text(json) | Top-level array elements as text rows
        json_array_length(json) | Number of top-level array elements
        json_each(json) | Top-level key/value pairs as rows
        json_each_text(json) | Top-level key/value pairs as text rows
        json_exists(json, path) | Whether a SQL/JSON path finds anything
        json_extract_path(json, key, …) | Value at a key path
        json_extract_path_text(json, key, …) | Value at a key path, as text
        json_object_keys(json) | Top-level keys as rows
        json_populate_record(base, json) | JSON object expanded into a row of base's type
        json_populate_recordset(base, json) | JSON array of objects expanded into rows
        json_query(json, path) | JSON fragment found by a SQL/JSON path
        json_scalar(value) | SQL scalar as a JSON value
        json_serialize(json) | JSON value as text or bytes
        json_strip_nulls(json) | Object fields with null values removed
        json_table(json, path COLUMNS (…)) AS alias | JSON data as relational rows
        json_to_record(json) AS x(…) | JSON object as a row with declared columns
        json_to_recordset(json) AS x(…) | JSON array of objects as rows with declared columns
        json_typeof(json) | Type of the outermost JSON value
        json_value(json, path [RETURNING type]) | Scalar found by a SQL/JSON path
        jsonb_array_elements(jsonb) | Top-level array elements as rows
        jsonb_array_elements_text(jsonb) | Top-level array elements as text rows
        jsonb_array_length(jsonb) | Number of top-level array elements
        jsonb_build_array(value, …) | jsonb array from the arguments
        jsonb_build_object(key, value, …) | jsonb object from alternating keys and values
        jsonb_each(jsonb) | Top-level key/value pairs as rows
        jsonb_each_text(jsonb) | Top-level key/value pairs as text rows
        jsonb_extract_path(jsonb, key, …) | Value at a key path
        jsonb_extract_path_text(jsonb, key, …) | Value at a key path, as text
        jsonb_insert(target, path, value[, insert_after]) | jsonb with a value inserted at a path
        jsonb_object(keys, values) | jsonb object from text arrays
        jsonb_object_keys(jsonb) | Top-level keys as rows
        jsonb_path_exists(jsonb, path[, vars]) | Whether a JSON path returns any item
        jsonb_path_match(jsonb, path[, vars]) | Result of a JSON path predicate
        jsonb_path_query(jsonb, path[, vars]) | Items returned by a JSON path, as rows
        jsonb_path_query_array(jsonb, path[, vars]) | Items returned by a JSON path, as an array
        jsonb_path_query_first(jsonb, path[, vars]) | First item returned by a JSON path
        jsonb_populate_record(base, jsonb) | jsonb object expanded into a row of base's type
        jsonb_populate_record_valid(base, jsonb) | Whether jsonb_populate_record would succeed
        jsonb_populate_recordset(base, jsonb) | jsonb array of objects expanded into rows
        jsonb_pretty(jsonb) | Indented JSON text
        jsonb_set_lax(target, path, value[, create_missing[, null_treatment]]) | jsonb_set with a choice for NULL values
        jsonb_strip_nulls(jsonb) | Object fields with null values removed
        jsonb_to_record(jsonb) AS x(…) | jsonb object as a row with declared columns
        jsonb_to_recordset(jsonb) AS x(…) | jsonb array of objects as rows with declared columns
        jsonb_typeof(jsonb) | Type of the outermost JSON value
        to_jsonb(value) | Any value converted to jsonb

        # Array
        array_append(array, element) | Array with an element added at the end
        array_cat(array1, array2) | Two arrays joined
        array_dims(array) | Dimensions as text
        array_fill(value, dimensions[, lower_bounds]) | Array filled with one value
        array_length(array, dimension) | Length along a dimension
        array_lower(array, dimension) | Lower bound of a dimension
        array_ndims(array) | Number of dimensions
        array_position(array, element[, start]) | Index of the first occurrence
        array_positions(array, element) | Indexes of every occurrence
        array_prepend(element, array) | Array with an element added at the front
        array_remove(array, element) | Array without elements equal to the value
        array_replace(array, from, to) | Array with matching elements replaced
        array_reverse(array) | Array in reverse order
        array_sample(array, n) | n randomly chosen elements
        array_shuffle(array) | Array in random order
        array_sort(array[, descending[, nulls_first]]) | Array sorted
        array_to_string(array, delimiter[, null_string]) | Array elements joined into text
        array_upper(array, dimension) | Upper bound of a dimension
        cardinality(array) | Total number of elements
        generate_subscripts(array, dimension) | Valid subscripts of a dimension, as rows
        trim_array(array, n) | Array without its last n elements
        unnest(array, …) | Array elements as rows

        # Range and multirange
        datemultirange(range, …) | daterange values as a multirange
        daterange(lower, upper[, bounds]) | Range of dates
        int4multirange(range, …) | int4range values as a multirange
        int4range(lower, upper[, bounds]) | Range of integers
        int8multirange(range, …) | int8range values as a multirange
        int8range(lower, upper[, bounds]) | Range of bigints
        isempty(range) | Whether the range is empty
        lower_inc(range) | Whether the lower bound is inclusive
        lower_inf(range) | Whether the lower bound is unbounded
        multirange(range) | One range as a multirange
        nummultirange(range, …) | numrange values as a multirange
        numrange(lower, upper[, bounds]) | Range of numerics
        range_merge(range1, range2) | Smallest range covering both
        tsmultirange(range, …) | tsrange values as a multirange
        tsrange(lower, upper[, bounds]) | Range of timestamps
        tstzmultirange(range, …) | tstzrange values as a multirange
        tstzrange(lower, upper[, bounds]) | Range of timestamps with time zone
        upper_inc(range) | Whether the upper bound is inclusive
        upper_inf(range) | Whether the upper bound is unbounded

        # Conditional and series
        generate_series(start, stop[, step]) | Series of values as rows
        num_nonnulls(value, …) | Number of non-null arguments
        num_nulls(value, …) | Number of null arguments

        # Full-text search
        array_to_tsvector(text[]) | Lexemes as a tsvector
        get_current_ts_config() | Default text search configuration
        json_to_tsvector(config, json, filter) | tsvector from JSON values
        jsonb_to_tsvector(config, jsonb, filter) | tsvector from jsonb values
        numnode(tsquery) | Number of lexemes and operators
        phraseto_tsquery([config,] text) | Phrase query from plain text
        plainto_tsquery([config,] text) | AND query from plain text
        querytree(tsquery) | Indexable part of a query
        setweight(tsvector, weight) | Weight applied to every lexeme
        strip(tsvector) | tsvector without positions and weights
        to_tsquery([config,] text) | Query from operator syntax
        to_tsvector([config,] document) | Document reduced to lexemes
        ts_debug([config,] document) | Parsing and dictionary steps, for debugging
        ts_delete(tsvector, lexeme) | tsvector without the given lexemes
        ts_filter(tsvector, weights) | Lexemes with the given weights only
        ts_headline([config,] document, query[, options]) | Document with query matches highlighted
        ts_lexize(dictionary, token) | Lexemes a dictionary produces for a token
        ts_parse(parser, document) | Tokens produced by a parser
        ts_rank([weights,] vector, query[, normalization]) | Relevance by match frequency
        ts_rank_cd([weights,] vector, query[, normalization]) | Relevance by cover density
        ts_rewrite(query, target, substitute) | Query with parts substituted
        ts_stat(sqlquery[, weights]) | Lexeme statistics of a tsvector column
        ts_token_type(parser) | Token types a parser knows
        tsquery_phrase(query1, query2[, distance]) | Phrase query from two queries
        tsvector_to_array(tsvector) | Lexemes as a text array
        websearch_to_tsquery([config,] text) | Query from web-search style input

        # UUID
        gen_random_uuid() | New random (version 4) UUID
        uuid_extract_timestamp(uuid) | Timestamp embedded in a v1 or v7 UUID
        uuid_extract_version(uuid) | Version number of a UUID
        uuidv4() | New random (version 4) UUID
        uuidv7([shift]) | New time-ordered (version 7) UUID

        # Network
        abbrev(inet) | Abbreviated address text
        broadcast(inet) | Broadcast address of the network
        family(inet) | 4 or 6
        host(inet) | Address without the netmask
        hostmask(inet) | Host mask of the network
        inet_merge(inet, inet) | Smallest network containing both
        inet_same_family(inet, inet) | Whether both are IPv4 or both IPv6
        masklen(inet) | Netmask length
        netmask(inet) | Netmask of the network
        network(inet) | Network part of the address
        set_masklen(inet, length) | Address with a new netmask length

        # Geometry
        area(object) | Area
        bound_box(box, box) | Box enclosing both
        box(…) | Box from points or another shape
        center(object) | Center point
        circle(…) | Circle from a center and radius, or another shape
        diagonal(box) | Diagonal as a line segment
        diameter(circle) | Diameter
        height(box) | Vertical size
        isclosed(path) | Whether the path is closed
        isopen(path) | Whether the path is open
        line(point, point) | Line through two points
        lseg(point, point) | Line segment between two points
        npoints(path) | Number of points
        path(polygon) | Polygon as a closed path
        pclose(path) | Path marked closed
        point(x, y) | Point from coordinates
        polygon(…) | Polygon from a path, box or circle
        popen(path) | Path marked open
        radius(circle) | Radius
        slope(point, point) | Slope of the line through two points
        width(box) | Horizontal size

        # Enum
        enum_first(enum_value) | First value of the enum type
        enum_last(enum_value) | Last value of the enum type
        enum_range(enum_value[, enum_value]) | Values of the enum type, as an array

        # XML
        database_to_xml(nulls, tableforest, targetns) | Whole database as XML
        query_to_xml(query, nulls, tableforest, targetns) | Query result as XML
        query_to_xmlschema(query, nulls, tableforest, targetns) | XML schema of a query result
        schema_to_xml(schema, nulls, tableforest, targetns) | Schema contents as XML
        table_to_xml(table, nulls, tableforest, targetns) | Table rows as XML
        table_to_xmlschema(table, nulls, tableforest, targetns) | XML schema of a table
        xml_is_well_formed(text) | Whether text is well-formed XML
        xml_is_well_formed_content(text) | Whether text is well-formed XML content
        xml_is_well_formed_document(text) | Whether text is a well-formed XML document
        xmlcomment(text) | XML comment
        xmlconcat(xml, …) | XML values concatenated
        xmlelement(NAME name [, XMLATTRIBUTES(…)] [, content, …]) | XML element
        xmlexists(xpath PASSING xml) | Whether an XPath matches
        xmlforest(value [AS name], …) | Sequence of XML elements
        xmlparse(DOCUMENT|CONTENT text) | XML value parsed from text
        xmlpi(NAME target[, content]) | XML processing instruction
        xmlroot(xml, VERSION text[, STANDALONE yes|no]) | XML root node properties changed
        xmlserialize(DOCUMENT|CONTENT xml AS type) | XML value as text
        xmltable(xpath PASSING xml COLUMNS …) | XML data as relational rows
        xmltext(text) | Text escaped as an XML text node
        xpath(xpath, xml[, namespaces]) | Nodes matched by an XPath
        xpath_exists(xpath, xml[, namespaces]) | Whether an XPath matches

        # Session and system information
        current_catalog | Name of the current database
        current_database() | Name of the current database
        current_query() | Text of the query being run
        current_role | Same as CURRENT_USER
        current_schema() | First schema on the search path
        current_schemas(include_implicit) | Schemas on the search path
        current_setting(name[, missing_ok]) | Value of a configuration setting
        inet_client_addr() | Client address
        inet_client_port() | Client port
        inet_server_addr() | Server address
        inet_server_port() | Server port
        pg_backend_pid() | Process id of this session's backend
        pg_blocking_pids(pid) | Sessions blocking a process
        pg_conf_load_time() | When the configuration was last loaded
        pg_current_logfile([type]) | Log file in use
        pg_is_in_recovery() | Whether this server is a standby
        pg_jit_available() | Whether JIT compilation can be used
        pg_last_xact_replay_timestamp() | Commit time of the last replayed transaction
        pg_listening_channels() | Channels this session LISTENs on
        pg_my_temp_schema() | This session's temporary schema
        pg_notify(channel, payload) | Sends a NOTIFY
        pg_postmaster_start_time() | Server start time
        pg_trigger_depth() | Trigger nesting level
        set_config(name, value, is_local) | Changes a configuration setting
        version() | Server version string

        # Privileges and catalog lookups
        col_description(table, column_number) | Comment on a column
        format_type(type_oid, typemod) | SQL name of a type
        has_any_column_privilege([user,] table, privilege) | Whether a user may act on any column of a table
        has_column_privilege([user,] table, column, privilege) | Whether a user may act on a column
        has_database_privilege([user,] database, privilege) | Whether a user may act on a database
        has_foreign_data_wrapper_privilege([user,] fdw, privilege) | Whether a user may use a foreign-data wrapper
        has_function_privilege([user,] function, privilege) | Whether a user may run a function
        has_language_privilege([user,] language, privilege) | Whether a user may use a procedural language
        has_parameter_privilege([user,] parameter, privilege) | Whether a user may set a configuration parameter
        has_schema_privilege([user,] schema, privilege) | Whether a user may act on a schema
        has_sequence_privilege([user,] sequence, privilege) | Whether a user may act on a sequence
        has_server_privilege([user,] server, privilege) | Whether a user may use a foreign server
        has_table_privilege([user,] table, privilege) | Whether a user may act on a table
        has_tablespace_privilege([user,] tablespace, privilege) | Whether a user may create objects in a tablespace
        has_type_privilege([user,] type, privilege) | Whether a user may use a type
        obj_description(oid, catalog) | Comment on a database object
        pg_basetype(regtype) | Base type of a domain
        pg_function_is_visible(oid) | Whether the function is on the search path
        pg_get_constraintdef(oid[, pretty]) | Definition of a constraint
        pg_get_expr(node, relation[, pretty]) | Stored expression as SQL
        pg_get_function_arguments(oid) | Argument list of a function
        pg_get_function_identity_arguments(oid) | Arguments that identify a function
        pg_get_function_result(oid) | Return type of a function
        pg_get_functiondef(oid) | CREATE FUNCTION statement of a function
        pg_get_indexdef(oid) | CREATE INDEX statement of an index
        pg_get_keywords() | SQL keywords and their categories
        pg_get_partkeydef(oid) | Partition key of a table
        pg_get_ruledef(oid[, pretty]) | CREATE RULE statement of a rule
        pg_get_serial_sequence(table, column) | Sequence behind a serial or identity column
        pg_get_statisticsobjdef(oid) | CREATE STATISTICS statement
        pg_get_triggerdef(oid[, pretty]) | CREATE TRIGGER statement of a trigger
        pg_get_userbyid(role_oid) | Role name for an oid
        pg_get_viewdef(view[, pretty]) | SELECT behind a view
        pg_has_role([user,] role, privilege) | Whether a user has a role
        pg_input_error_info(text, type) | Error a text would raise as input for a type
        pg_input_is_valid(text, type) | Whether text is valid input for a type
        pg_is_other_temp_schema(oid) | Whether the schema is another session's temp schema
        pg_table_is_visible(oid) | Whether the table is on the search path
        pg_tablespace_location(tablespace_oid) | Directory of a tablespace
        pg_type_is_visible(oid) | Whether the type is on the search path
        pg_typeof(value) | Data type of a value
        row_security_active(table) | Whether row security applies to a table
        shobj_description(oid, catalog) | Comment on a shared object
        to_regclass(text) | Relation oid for a name, or NULL
        to_regcollation(text) | Collation oid for a name, or NULL
        to_regnamespace(text) | Schema oid for a name, or NULL
        to_regoper(text) | Operator oid for a name, or NULL
        to_regoperator(text) | Operator oid for a signature, or NULL
        to_regproc(text) | Function oid for a name, or NULL
        to_regprocedure(text) | Function oid for a signature, or NULL
        to_regrole(text) | Role oid for a name, or NULL
        to_regtype(text) | Type oid for a name, or NULL
        to_regtypemod(text) | Type modifier for a type name, or NULL

        # Sizes and storage
        pg_column_compression(value) | Compression method of a stored value
        pg_column_size(value) | Bytes used to store a value
        pg_database_size(database) | Disk space used by a database
        pg_indexes_size(table) | Disk space used by a table's indexes
        pg_partition_ancestors(table) | Partition and its ancestors
        pg_partition_root(table) | Top of a partition tree
        pg_partition_tree(table) | Partitions under a table
        pg_relation_filepath(relation) | File path of a relation
        pg_relation_size(relation[, fork]) | Disk space used by one fork of a relation
        pg_size_bytes(text) | Bytes in a human-readable size such as '10 MB'
        pg_size_pretty(bytes) | Byte count as a human-readable size
        pg_table_size(table) | Disk space of a table without indexes
        pg_tablespace_size(tablespace) | Disk space used by a tablespace
        pg_total_relation_size(table) | Disk space of a table with indexes and TOAST

        # Server control, locks and sleeping
        pg_advisory_lock(key) | Takes a session-level advisory lock
        pg_advisory_lock_shared(key) | Takes a shared session-level advisory lock
        pg_advisory_unlock(key) | Releases a session-level advisory lock
        pg_advisory_unlock_all() | Releases every advisory lock of the session
        pg_advisory_unlock_shared(key) | Releases a shared session-level advisory lock
        pg_advisory_xact_lock(key) | Takes a transaction-level advisory lock
        pg_advisory_xact_lock_shared(key) | Takes a shared transaction-level advisory lock
        pg_cancel_backend(pid) | Cancels the running query of a session
        pg_ls_dir(directory) | Files in a server directory
        pg_ls_logdir() | Files in the log directory
        pg_ls_waldir() | Files in the WAL directory
        pg_read_binary_file(filename[, offset, length]) | Server file contents as bytes
        pg_read_file(filename[, offset, length]) | Server file contents as text
        pg_reload_conf() | Makes the server reload its configuration
        pg_rotate_logfile() | Switches to a new log file
        pg_sleep(seconds) | Pauses the session
        pg_sleep_for(interval) | Pauses for an interval
        pg_sleep_until(timestamp) | Pauses until a time
        pg_stat_file(filename) | Size and times of a server file
        pg_stat_reset() | Zeroes this database's statistics counters
        pg_terminate_backend(pid[, timeout]) | Ends a session
        pg_try_advisory_lock(key) | Takes a session-level advisory lock if free
        pg_try_advisory_lock_shared(key) | Takes a shared session-level advisory lock if free
        pg_try_advisory_xact_lock(key) | Takes a transaction-level advisory lock if free
        pg_try_advisory_xact_lock_shared(key) | Takes a shared transaction-level advisory lock if free

        # Transactions, snapshots and WAL
        pg_backup_start(label[, fast]) | Prepares the server for an online backup
        pg_backup_stop([wait_for_archive]) | Finishes an online backup
        pg_create_logical_replication_slot(name, plugin) | New logical replication slot
        pg_create_physical_replication_slot(name) | New physical replication slot
        pg_create_restore_point(name) | Named restore point in the WAL
        pg_current_snapshot() | Current snapshot
        pg_current_wal_lsn() | WAL write location
        pg_current_xact_id() | Id of the current transaction, assigning one
        pg_current_xact_id_if_assigned() | Id of the current transaction, or NULL
        pg_drop_replication_slot(name) | Drops a replication slot
        pg_export_snapshot() | Exports the snapshot for other sessions
        pg_is_wal_replay_paused() | Whether recovery is paused
        pg_last_committed_xact() | Id and time of the latest commit
        pg_last_wal_receive_lsn() | Last WAL location received by a standby
        pg_last_wal_replay_lsn() | Last WAL location replayed by a standby
        pg_logical_slot_get_changes(slot, upto_lsn, upto_nchanges, …) | Consumes changes from a slot
        pg_logical_slot_peek_changes(slot, upto_lsn, upto_nchanges, …) | Reads changes from a slot without consuming them
        pg_promote([wait[, wait_seconds]]) | Promotes a standby
        pg_switch_wal() | Forces a switch to a new WAL file
        pg_wal_lsn_diff(lsn1, lsn2) | Bytes between two WAL locations
        pg_wal_replay_pause() | Pauses recovery
        pg_wal_replay_resume() | Resumes recovery
        pg_walfile_name(lsn) | WAL file holding a location
        pg_xact_commit_timestamp(xid) | Commit time of a transaction
        pg_xact_status(xid8) | Commit status of a transaction
        txid_current() | Id of the current transaction (older API)

        # Sequences, large objects and extensions
        currval(sequence) | Value nextval last returned in this session
        lastval() | Value of the most recent nextval in this session
        nextval(sequence) | Advances a sequence and returns the value
        pg_sequence_last_value(sequence) | Last value of a sequence, or NULL
        setval(sequence, value[, is_called]) | Sets a sequence's current value
        lo_create(oid) | New large object
        lo_export(oid, filename) | Writes a large object to a server file
        lo_from_bytea(oid, bytes) | New large object holding the bytes
        lo_get(oid[, offset, length]) | Large object contents
        lo_import(filename[, oid]) | New large object from a server file
        lo_put(oid, offset, bytes) | Writes bytes into a large object
        lo_unlink(oid) | Deletes a large object
        pg_available_extension_versions() | Installable extension versions
        pg_available_extensions() | Installable extensions
        pg_event_trigger_ddl_commands() | Commands seen by a ddl_command_end trigger
        pg_event_trigger_dropped_objects() | Objects dropped, seen by an sql_drop trigger
        pg_client_encoding() | Client character set
        getdatabaseencoding() | Database character set
        """

    static let sqliteFunctionTable = """
        acosh(x) | Inverse hyperbolic cosine
        asinh(x) | Inverse hyperbolic sine
        atanh(x) | Inverse hyperbolic tangent
        bm25(fts_table[, weight, …]) | FTS5 relevance score
        changes() | Rows changed by the last INSERT, UPDATE or DELETE
        char(code, …) | Characters for Unicode code points
        cosh(x) | Hyperbolic cosine
        datetime(time_value[, modifier, …]) | Date and time as YYYY-MM-DD HH:MM:SS
        glob(pattern, text) | Case-sensitive match with * and ? wildcards
        hex(value) | Hexadecimal text of a value's bytes
        highlight(fts_table, column, open, close) | FTS5 match with markers around hits
        if(condition, then[, else]) | Same as iif
        iif(condition, then, else) | then when condition is true, else otherwise
        json(text) | Minified JSON text
        json_array_length(json[, path]) | Number of array elements
        json_each(json[, path]) | Top-level elements as rows
        json_error_position(text) | Position of the first JSON syntax error, 0 if none
        json_group_array(value) | Group's values gathered into a JSON array
        json_group_object(name, value) | Group's pairs gathered into a JSON object
        json_patch(target, patch) | Document merged with an RFC 7396 patch
        json_pretty(json[, indent]) | Indented JSON text
        json_quote(value) | SQL value as JSON
        json_tree(json[, path]) | Every element of a document as rows
        jsonb(json) | Binary JSON encoding of a document
        jsonb_array(value, …) | Binary JSON array
        jsonb_extract(json, path, …) | Value at a path, as binary JSON
        jsonb_group_array(value) | Group's values gathered into a binary JSON array
        jsonb_group_object(name, value) | Group's pairs gathered into a binary JSON object
        jsonb_insert(json, path, value, …) | json_insert returning binary JSON
        jsonb_object(label, value, …) | Binary JSON object
        jsonb_patch(target, patch) | json_patch returning binary JSON
        jsonb_remove(json, path, …) | json_remove returning binary JSON
        jsonb_replace(json, path, value, …) | json_replace returning binary JSON
        julianday(time_value[, modifier, …]) | Fractional Julian day number
        last_insert_rowid() | Rowid of the most recent INSERT on this connection
        likelihood(condition, probability) | Planner hint: chance the condition is true
        likely(condition) | Planner hint: the condition is usually true
        log2(x) | Base-2 logarithm
        printf(format, …) | Same as FORMAT
        quote(value) | Value written as an SQL literal
        random() | Random 64-bit integer
        randomblob(n) | n random bytes
        sinh(x) | Hyperbolic sine
        snippet(fts_table, column, open, close, ellipsis, tokens) | FTS5 excerpt around hits
        sqlite_compileoption_get(n) | nth compile-time option
        sqlite_compileoption_used(name) | Whether a compile-time option was set
        sqlite_source_id() | Source check-in of the library
        sqlite_version() | Library version
        strftime(format, time_value[, modifier, …]) | Date/time rendered with % specifiers
        tanh(x) | Hyperbolic tangent
        timediff(time1, time2) | Difference between two times as text
        total(expr) | Sum as a float; 0.0 for no rows
        total_changes() | Rows changed since the connection opened
        typeof(value) | Storage class: null, integer, real, text or blob
        unhex(text[, ignore]) | Bytes from hexadecimal text
        unicode(text) | Code point of the first character
        unistr(text) | Text with \\uXXXX escapes decoded
        unixepoch(time_value[, modifier, …]) | Seconds since 1970-01-01
        unlikely(condition) | Planner hint: the condition is usually false
        uuid() | New random UUID text
        uuid_blob(uuid) | UUID as 16 bytes
        uuid_str(uuid) | UUID as text
        zeroblob(n) | n zero bytes
        """

    static let duckdbFunctionTable = """
        # Reading files and table functions
        generate_series(start, stop[, step]) | Number or timestamp series as rows, including stop
        glob(pattern) | Files matching a glob pattern, as rows
        parquet_metadata(path) | Row-group metadata of Parquet files
        parquet_schema(path) | Schema of Parquet files
        query(sql) | Rows of a query given as text
        query_table(name) | Rows of a table named by text
        range(start, stop[, step]) | Number series as rows, excluding stop
        read_blob(path) | Files as rows of bytes
        read_csv(path, …) | CSV files as a table, sniffing the format
        read_csv_auto(path, …) | Same as read_csv
        read_json(path, …) | JSON files as a table
        read_json_auto(path, …) | Same as read_json
        read_json_objects(path, …) | JSON files, one object per row
        read_ndjson(path, …) | Newline-delimited JSON files as a table
        read_ndjson_auto(path, …) | Same as read_ndjson
        read_parquet(path, …) | Parquet files as a table
        read_text(path) | Files as rows of text
        sniff_csv(path) | Detected CSV dialect and columns
        unnest(list) | List elements as rows; struct fields as columns

        # Catalog
        current_database() | Name of the current database
        current_schema() | Name of the current schema
        duckdb_columns() | Columns of every table
        duckdb_databases() | Attached databases
        duckdb_extensions() | Known extensions
        duckdb_functions() | Available functions
        duckdb_indexes() | Indexes
        duckdb_schemas() | Schemas
        duckdb_settings() | Settings and their values
        duckdb_tables() | Tables
        duckdb_types() | Data types
        duckdb_views() | Views
        version() | DuckDB version

        # Lists
        array_to_string(list, separator) | List elements joined into text
        flatten(list_of_lists) | Nested list flattened one level
        len(list) | Length of a list or string
        list_aggregate(list, name, …) | Named aggregate applied to the list
        list_any_value(list) | First non-null element
        list_append(list, element) | List with an element added at the end
        list_avg(list) | Average of the elements
        list_concat(list1, list2) | Two lists joined
        list_contains(list, element) | Whether the list holds the element
        list_count(list) | Number of non-null elements
        list_distinct(list) | Unique non-null elements
        list_extract(list, index) | Element at a 1-based index
        list_filter(list, lambda) | Elements for which the lambda is true
        list_first(list) | First element
        list_grade_up(list) | Indexes that would sort the list
        list_has_all(list, sub_list) | Whether every element of sub_list is present
        list_has_any(list1, list2) | Whether the lists share an element
        list_intersect(list1, list2) | Elements present in both lists
        list_last(list) | Last element
        list_max(list) | Largest element
        list_min(list) | Smallest element
        list_position(list, element) | 1-based index of the element, or NULL
        list_prepend(element, list) | List with an element added at the front
        list_reduce(list, lambda) | List folded into one value with a lambda
        list_resize(list, size[, value]) | List padded or cut to a size
        list_reverse(list) | List in reverse order
        list_reverse_sort(list) | List sorted descending
        list_select(list, indexes) | Elements at the given indexes
        list_slice(list, begin, end[, step]) | Part of a list
        list_sort(list[, order[, nulls]]) | List sorted
        list_string_agg(list[, separator]) | Elements joined into text
        list_sum(list) | Sum of the elements
        list_transform(list, lambda) | Each element mapped through a lambda
        list_unique(list) | Number of distinct non-null elements
        list_value(value, …) | List from the arguments
        list_where(list, mask) | Elements where the boolean mask is true
        list_zip(list1, list2, …) | Lists combined into a list of structs

        # Structs, maps and unions
        element_at(map, key) | Value for a key
        map(keys, values) | Map from a key list and a value list
        map_concat(map, …) | Maps merged
        map_contains(map, key) | Whether the map has the key
        map_entries(map) | Key/value structs of a map
        map_extract(map, key) | Value for a key, as a list
        map_from_entries(entries) | Map from key/value structs
        map_keys(map) | Keys of a map
        map_values(map) | Values of a map
        row(value, …) | Unnamed struct from the arguments
        struct_extract(struct, field) | One field of a struct
        struct_insert(struct, name := value, …) | Struct with fields added
        struct_pack(name := value, …) | Struct with named fields
        union_extract(union, tag) | Value of one union member
        union_tag(union) | Tag of the active union member
        union_value(tag := value) | Union with one member set

        # Aggregates
        approx_count_distinct(expr) | Estimated number of distinct values
        approx_quantile(expr, quantile) | Estimated quantile
        arg_max(arg, value) | arg from the row with the largest value
        arg_min(arg, value) | arg from the row with the smallest value
        bool_and(expr) | True when every value is true
        bool_or(expr) | True when any value is true
        count_if(condition) | Rows where the condition is true
        first(expr) | First value of the group
        histogram(expr) | Map of values to counts
        kurtosis(expr) | Kurtosis of the values
        last(expr) | Last value of the group
        list(expr) | Group's values gathered into a list
        mad(expr) | Median absolute deviation
        max_by(arg, value) | Same as arg_max
        median(expr) | Middle value
        min_by(arg, value) | Same as arg_min
        mode(expr) | Most frequent value
        product(expr) | Product of the values
        quantile_cont(expr, quantile) | Interpolated quantile
        quantile_disc(expr, quantile) | Quantile picked from the values
        skewness(expr) | Skewness of the values
        stddev_pop(expr) | Population standard deviation
        stddev_samp(expr) | Sample standard deviation
        var_pop(expr) | Population variance
        var_samp(expr) | Sample variance
        weighted_avg(value, weight) | Weighted average

        # Date and time
        dayofmonth(date) | Day of the month
        epoch(timestamp) | Seconds since 1970-01-01
        epoch_ms(value) | Milliseconds since the epoch, or a timestamp from them
        epoch_ns(timestamp) | Nanoseconds since the epoch
        epoch_us(timestamp) | Microseconds since the epoch
        isodow(date) | ISO weekday where 1 is Monday
        isoyear(date) | ISO 8601 year
        make_date(year, month, day) | Date from parts
        make_time(hour, minute, seconds) | Time from parts
        make_timestamp(year, month, day, hour, minute, seconds) | Timestamp from parts
        strftime(timestamp, format) | Timestamp rendered with % specifiers
        strptime(text, format) | Timestamp parsed with % specifiers
        time_bucket(width, timestamp[, origin]) | Timestamp floored into fixed-width buckets
        to_days(n) | Interval of n days
        to_hours(n) | Interval of n hours
        to_minutes(n) | Interval of n minutes
        to_months(n) | Interval of n months
        to_seconds(n) | Interval of n seconds
        to_years(n) | Interval of n years
        today() | Current date
        try_strptime(text, format) | strptime that returns NULL instead of failing
        weekday(date) | Weekday number where 0 is Sunday
        yearweek(date) | ISO year and week as YYYYWW

        # Strings and regular expressions
        bar(x, min, max[, width]) | Text bar chart of a value
        contains(text, search) | Whether text contains search
        damerau_levenshtein(a, b) | Edit distance counting transpositions
        ends_with(text, suffix) | Whether text ends with suffix
        format_bytes(bytes) | Byte count in human units
        hamming(a, b) | Number of differing positions
        jaccard(a, b) | Jaccard similarity of the character sets
        jaro_winkler_similarity(a, b) | Jaro-Winkler similarity
        levenshtein(a, b) | Edit distance
        parse_filename(path[, trim_extension]) | Last component of a path
        parse_path(path) | Components of a path, as a list
        printf(format, …) | printf-style formatting
        regexp_extract(text, pattern[, group]) | Captured group of the first match
        regexp_extract_all(text, pattern[, group]) | Captured group of every match
        regexp_full_match(text, pattern) | Whether the whole text matches
        regexp_matches(text, pattern) | Whether any part of the text matches
        regexp_split_to_array(text, pattern) | Text split on a regular expression
        sha256(value) | SHA-256 digest as hex
        starts_with(text, prefix) | Whether text begins with prefix
        string_split(text, separator) | Text split into a list
        strip_accents(text) | Text without accents
        to_base64(bytes) | Bytes as base64
        from_base64(text) | Bytes from base64
        url_decode(text) | Percent-decoded text
        url_encode(text) | Percent-encoded text

        # Math and hashing
        bit_count(x) | Number of set bits
        cbrt(x) | Cube root
        even(x) | Rounded away from zero to an even number
        factorial(n) | n!
        gcd(a, b) | Greatest common divisor
        hash(value, …) | 64-bit hash of the values
        isinf(x) | Whether x is infinite
        isnan(x) | Whether x is NaN
        lcm(a, b) | Least common multiple
        log2(x) | Base-2 logarithm
        random() | Random number from 0 up to 1
        round_even(x, decimals) | Rounded half to even
        setseed(seed) | Seeds random()

        # JSON
        json_array_length(json[, path]) | Number of array elements
        json_each(json[, path]) | Top-level elements as rows
        json_exists(json, path) | Whether a path exists
        json_extract_string(json, path) | Value at a path, as text
        json_group_array(value) | Group's values gathered into a JSON array
        json_group_object(key, value) | Group's pairs gathered into a JSON object
        json_merge_patch(json, json, …) | Documents merged as RFC 7396 patches
        json_structure(json) | Structure of a document
        json_transform(json, structure) | JSON converted to a typed DuckDB value
        json_tree(json[, path]) | Every element of a document as rows
        json_value(json, path) | Scalar at a path

        # UUID, types and misc
        try_cast(expr AS type) | Like CAST, but NULL instead of an error
        current_setting(name) | Value of a setting
        currval(sequence) | Current value of a sequence
        enum_range(enum_value) | Values of an enum type
        error(message) | Raises an error
        gen_random_uuid() | New random UUID
        getvariable(name) | Value of a SET VARIABLE variable
        nextval(sequence) | Advances a sequence and returns the value
        typeof(value) | Name of the value's type
        uuid() | New random UUID
        uuidv7() | New time-ordered (version 7) UUID
        """
}
