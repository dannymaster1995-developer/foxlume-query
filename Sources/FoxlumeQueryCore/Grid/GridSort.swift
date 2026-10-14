import Foundation

/// What a click on a column header does to the sort, as in TablePro.
public enum SortCycle {
    /// A plain click makes `column` the only key: ascending, then descending, then no sort.
    /// A Shift-click (`additive`) appends it as the next key, flips it to descending, then removes it,
    /// leaving the other keys in place.
    public static func next(_ sort: [SortKey], clicking column: String, additive: Bool) -> [SortKey] {
        if additive {
            var keys = sort
            guard let index = keys.firstIndex(where: { $0.column == column }) else {
                return keys + [SortKey(column: column, ascending: true)]
            }
            if keys[index].ascending {
                keys[index].ascending = false
            } else {
                keys.remove(at: index)
            }
            return keys
        }
        guard let primary = sort.first, primary.column == column else {
            return [SortKey(column: column, ascending: true)]
        }
        return primary.ascending ? [SortKey(column: column, ascending: false)] : []
    }
}

/// Sorting rows already in memory (query results), stable and by several keys.
public enum LocalRowSort {
    public struct Key: Equatable, Sendable {
        public var column: Int
        public var ascending: Bool
        /// Numbers compare by value; everything else by `localizedStandardCompare`.
        public var numeric: Bool

        public init(column: Int, ascending: Bool, numeric: Bool) {
            self.column = column
            self.ascending = ascending
            self.numeric = numeric
        }
    }

    /// The row positions in sorted order. Rows that compare equal on every key keep their order. NULL sorts first
    /// ascending and last descending.
    public static func order(_ rows: [[CellValue]], by keys: [Key]) -> [Int] {
        guard !keys.isEmpty else { return Array(rows.indices) }
        return rows.indices.sorted { lhs, rhs in
            for key in keys {
                let left = rows[lhs].indices.contains(key.column) ? rows[lhs][key.column] : .null
                let right = rows[rhs].indices.contains(key.column) ? rows[rhs][key.column] : .null
                let result = compare(left, right, numeric: key.numeric)
                guard result != .orderedSame else { continue }
                return key.ascending ? result == .orderedAscending : result == .orderedDescending
            }
            return lhs < rhs
        }
    }

    public static func compare(_ lhs: CellValue, _ rhs: CellValue, numeric: Bool) -> ComparisonResult {
        switch (lhs.isAbsent, rhs.isAbsent) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedAscending
        case (false, true): return .orderedDescending
        case (false, false):
            let a = lhs.displayString
            let b = rhs.displayString
            if numeric, let x = Double(a), let y = Double(b) {
                return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
            }
            return a.localizedStandardCompare(b)
        }
    }
}
