import Foundation
import SQLite3

/// SQLite parses `x REGEXP y` but ships no function behind it. This registers `regexp(pattern, text)` on a connection,
/// backed by NSRegularExpression (ICU syntax, so `(?i)` turns on case-insensitive matching). NULL in, NULL out;
/// an invalid pattern is an SQL error.
enum SQLiteRegexp {
    static func register(on db: OpaquePointer) {
        sqlite3_create_function_v2(db, "regexp", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, count, arguments in
            guard let context, count == 2, let arguments,
                  let patternText = sqlite3_value_text(arguments[0]), let valueText = sqlite3_value_text(arguments[1])
            else { return sqlite3_result_null(context) }
            let pattern = String(cString: patternText)
            let value = String(cString: valueText)
            guard let expression = SQLiteRegexp.expression(pattern) else {
                return sqlite3_result_error(context, "Invalid regular expression: \(pattern)", -1)
            }
            let range = NSRange(value.startIndex..., in: value)
            sqlite3_result_int(context, expression.firstMatch(in: value, range: range) == nil ? 0 : 1)
        }, nil, nil, nil)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    /// A filter runs the same pattern over every row, so compiled patterns are kept (a few dozen at most).
    static func expression(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[pattern] = compiled
        return compiled
    }
}
