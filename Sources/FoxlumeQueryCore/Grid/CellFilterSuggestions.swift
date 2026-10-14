import Foundation

/// The conditions a cell's context menu offers under "Filter", each one true for the row it came from (as in TablePro).
public enum CellFilterSuggestions {
    /// Values longer than this are not offered; the filter would be unwieldy and slow.
    public static let maximumLength = 10_000

    /// - Parameter ordered: numbers and dates, which also get `>` and `<`.
    public static func rules(column: String, value: CellValue, ordered: Bool) -> [FilterRule] {
        switch value {
        case .null, .missing:
            return [FilterRule(column: column, op: .isNull), FilterRule(column: column, op: .isNotNull)]
        case .text(let text) where text.isEmpty:
            return [FilterRule(column: column, op: .isEmpty), FilterRule(column: column, op: .isNotEmpty)]
        case .text(let text):
            // Filters compare the text as typed; surrounding spaces and very long values would not find the row again.
            guard text.count <= maximumLength, text == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return [] }
            let operators: [FilterOperator] = ordered ? [.equals, .notEquals, .greaterThan, .lessThan] : [.equals, .notEquals, .contains]
            return operators.map { FilterRule(column: column, op: $0, value: text) }
        case .bytes, .expression:
            return []
        }
    }

    /// Whether a column's values order as numbers or dates.
    public static func isOrdered(_ column: ResultColumn) -> Bool {
        if column.isNumeric { return true }
        let type = column.typeName.lowercased()
        return ["date", "time", "year", "interval"].contains { type.contains($0) }
    }
}

extension FilterRule {
    /// A short description for menus: `status = paid`, `total between 10 and 20`, `note is empty`.
    public var summary: String {
        func shown(_ text: String) -> String { text.count > 40 ? String(text.prefix(40)) + "…" : text }
        switch op {
        case .between, .notBetween: return "\(column) \(op.title) \(shown(value)) and \(shown(secondValue))"
        case _ where !op.needsValue: return "\(column) \(op.title)"
        default: return "\(column) \(op.title) \(shown(value))" + (matchCase && op.supportsMatchCase ? " (match case)" : "")
        }
    }
}
