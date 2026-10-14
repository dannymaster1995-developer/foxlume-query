import Foundation

/// Figures for the selected cells, shown in the status bar: how many hold a value and, for numbers, sum, average,
/// minimum and maximum. Decimal arithmetic, so 0.1 + 0.2 is 0.3.
public struct SelectionStatistics: Equatable, Sendable {
    /// Selected cells, NULL ones included.
    public var cellCount = 0
    /// Cells that are not NULL (or a missing field).
    public var valueCount = 0
    /// Values of numeric columns that read as numbers; only these feed the figures below.
    public var numberCount = 0
    public var sum: Decimal?
    public var minimum: Decimal?
    public var maximum: Decimal?

    public init() {}

    /// - Parameter cells: each selected value and whether its column is numeric.
    public init<S: Sequence>(_ cells: S) where S.Element == (value: CellValue, numeric: Bool) {
        for cell in cells {
            cellCount += 1
            guard !cell.value.isAbsent else { continue }
            valueCount += 1
            guard cell.numeric, let number = Self.number(cell.value) else { continue }
            numberCount += 1
            sum = (sum ?? 0) + number
            minimum = minimum.map { Swift.min($0, number) } ?? number
            maximum = maximum.map { Swift.max($0, number) } ?? number
        }
    }

    public var average: Decimal? {
        guard let sum, numberCount > 0 else { return nil }
        return sum / Decimal(numberCount)
    }

    static func number(_ value: CellValue) -> Decimal? {
        guard case .text(let text) = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// "Count 4 · Sum 10 · Average 2.5 · Min 1 · Max 4"; only the count when no selected value is a number.
    public var summary: String {
        var parts = ["Count \(valueCount)"]
        if let sum, let average, let minimum, let maximum {
            parts += ["Sum \(Self.format(sum))", "Average \(Self.format(average, fractionDigits: 6))",
                      "Min \(Self.format(minimum))", "Max \(Self.format(maximum))"]
        }
        return parts.joined(separator: " · ")
    }

    /// Plain digits with a `.` separator, rounded to `fractionDigits` when given, without trailing zeros.
    public static func format(_ value: Decimal, fractionDigits: Int? = nil) -> String {
        var number = value
        if let fractionDigits {
            var source = value
            NSDecimalRound(&number, &source, fractionDigits, .plain)
        }
        return NSDecimalNumber(decimal: number).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }
}
