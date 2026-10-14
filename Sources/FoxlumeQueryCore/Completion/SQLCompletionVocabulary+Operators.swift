import Foundation

// Operators (spec 6.4). Symbols shared by several categories (`@>`, `<@`, `&&`, `@@`, `||`, `<<`, `>>`) appear once,
// listing every type they apply to, so a dedupe on label never drops one meaning.

extension SQLCompletionVocabulary {
    static let genericOperatorList: [SQLOperatorEntry] = [
        SQLOperatorEntry(symbol: "=", summary: "Equal to"),
        SQLOperatorEntry(symbol: "<>", summary: "Not equal to"),
        SQLOperatorEntry(symbol: "!=", summary: "Not equal to (alternative spelling of <>)"),
        SQLOperatorEntry(symbol: "<", summary: "Less than"),
        SQLOperatorEntry(symbol: ">", summary: "Greater than"),
        SQLOperatorEntry(symbol: "<=", summary: "Less than or equal to"),
        SQLOperatorEntry(symbol: ">=", summary: "Greater than or equal to"),
        SQLOperatorEntry(symbol: "<=>", summary: "Equal to, where two NULLs count as equal (MySQL)"),
    ]

    static let postgresqlOperatorList: [SQLOperatorEntry] = [
        // Cast
        SQLOperatorEntry(symbol: "::", types: "any", summary: "Converts the value on the left to the type on the right"),
        // Comparison
        SQLOperatorEntry(symbol: "=", types: "any", summary: "Equal to"),
        SQLOperatorEntry(symbol: "<>", types: "any", summary: "Not equal to"),
        SQLOperatorEntry(symbol: "!=", types: "any", summary: "Not equal to"),
        SQLOperatorEntry(symbol: "<", types: "any", summary: "Less than"),
        SQLOperatorEntry(symbol: ">", types: "any", summary: "Greater than"),
        SQLOperatorEntry(symbol: "<=", types: "any", summary: "Less than or equal to"),
        SQLOperatorEntry(symbol: ">=", types: "any", summary: "Greater than or equal to"),
        SQLOperatorEntry(symbol: "IS DISTINCT FROM", types: "any", summary: "Not equal, treating NULL as an ordinary value"),
        SQLOperatorEntry(symbol: "IS NOT DISTINCT FROM", types: "any", summary: "Equal, treating NULL as an ordinary value"),
        SQLOperatorEntry(symbol: "IS NULL", types: "any", summary: "True when the value is NULL"),
        SQLOperatorEntry(symbol: "IS NOT NULL", types: "any", summary: "True when the value is not NULL"),
        SQLOperatorEntry(symbol: "BETWEEN SYMMETRIC", types: "any", summary: "Range test that accepts the bounds in either order"),
        // Pattern matching and strings
        SQLOperatorEntry(symbol: "||", types: "text, array, jsonb, tsvector", summary: "Concatenates strings, arrays, jsonb values or tsvectors"),
        SQLOperatorEntry(symbol: "^@", types: "text", summary: "Starts with"),
        SQLOperatorEntry(symbol: "~", types: "text", summary: "Matches a regular expression, case-sensitive"),
        SQLOperatorEntry(symbol: "~*", types: "text", summary: "Matches a regular expression, ignoring case"),
        SQLOperatorEntry(symbol: "!~", types: "text", summary: "Does not match a regular expression, case-sensitive"),
        SQLOperatorEntry(symbol: "!~*", types: "text", summary: "Does not match a regular expression, ignoring case"),
        SQLOperatorEntry(symbol: "~~", types: "text", summary: "LIKE"),
        SQLOperatorEntry(symbol: "~~*", types: "text", summary: "ILIKE"),
        SQLOperatorEntry(symbol: "!~~", types: "text", summary: "NOT LIKE"),
        SQLOperatorEntry(symbol: "!~~*", types: "text", summary: "NOT ILIKE"),
        // JSON
        SQLOperatorEntry(symbol: "->", types: "json, jsonb", summary: "Object field by key or array element by index"),
        SQLOperatorEntry(symbol: "->>", types: "json, jsonb", summary: "Object field or array element, as text"),
        SQLOperatorEntry(symbol: "#>", types: "json, jsonb", summary: "Value at a path given as a text array"),
        SQLOperatorEntry(symbol: "#>>", types: "json, jsonb", summary: "Value at a path given as a text array, as text"),
        SQLOperatorEntry(symbol: "@>", types: "jsonb, array, range", summary: "Contains the right-hand value"),
        SQLOperatorEntry(symbol: "<@", types: "jsonb, array, range", summary: "Is contained in the right-hand value"),
        SQLOperatorEntry(symbol: "?", types: "jsonb", summary: "Has the key, or the string as an array element"),
        SQLOperatorEntry(symbol: "?|", types: "jsonb", summary: "Has any of the keys in a text array"),
        SQLOperatorEntry(symbol: "?&", types: "jsonb", summary: "Has all of the keys in a text array"),
        SQLOperatorEntry(symbol: "#-", types: "jsonb", summary: "Removes the value at a path"),
        SQLOperatorEntry(symbol: "@?", types: "jsonb", summary: "JSON path returns at least one item"),
        SQLOperatorEntry(symbol: "@@", types: "tsvector, tsquery, jsonb", summary: "Full-text match, or the result of a JSON path predicate"),
        // Arrays and ranges
        SQLOperatorEntry(symbol: "&&", types: "array, range", summary: "Overlaps: shares at least one element or point"),
        SQLOperatorEntry(symbol: "<<", types: "range, inet, integer", summary: "Strictly left of (range), contained in (inet), shift left (integer)"),
        SQLOperatorEntry(symbol: ">>", types: "range, inet, integer", summary: "Strictly right of (range), contains (inet), shift right (integer)"),
        SQLOperatorEntry(symbol: "&<", types: "range", summary: "Does not extend to the right of"),
        SQLOperatorEntry(symbol: "&>", types: "range", summary: "Does not extend to the left of"),
        SQLOperatorEntry(symbol: "-|-", types: "range", summary: "Is adjacent to"),
        // Full-text search
        SQLOperatorEntry(symbol: "<->", types: "tsquery, point", summary: "Followed by (tsquery), distance between (geometry)"),
        SQLOperatorEntry(symbol: "!!", types: "tsquery", summary: "Negates a tsquery"),
        // Network
        SQLOperatorEntry(symbol: "<<=", types: "inet", summary: "Is contained in or equal to the network"),
        SQLOperatorEntry(symbol: ">>=", types: "inet", summary: "Contains or equals the network"),
        // Math and bits
        SQLOperatorEntry(symbol: "^", types: "numeric", summary: "Exponentiation"),
        SQLOperatorEntry(symbol: "|/", types: "numeric", summary: "Square root"),
        SQLOperatorEntry(symbol: "||/", types: "numeric", summary: "Cube root"),
        SQLOperatorEntry(symbol: "@", types: "numeric", summary: "Absolute value"),
        SQLOperatorEntry(symbol: "%", types: "numeric", summary: "Remainder"),
        SQLOperatorEntry(symbol: "#", types: "integer, bit", summary: "Bitwise XOR"),
        SQLOperatorEntry(symbol: "&", types: "integer, bit", summary: "Bitwise AND"),
        SQLOperatorEntry(symbol: "|", types: "integer, bit", summary: "Bitwise OR"),
    ]
}
