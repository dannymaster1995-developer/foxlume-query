import Foundation

/// Dates and times as Excel stores them: days since the epoch of the workbook's date system as a number,
/// the time of day as its fraction. The 1900 system counts from 1899-12-30 for dates from 1900-03-01 on
/// (Excel keeps Lotus 1-2-3's 1900-02-29); the 1904 system counts from 1904-01-01.
enum ExcelDate {
    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static let epoch1900 = days(year: 1899, month: 12, day: 30)
    private static let epoch1904 = days(year: 1904, month: 1, day: 1)
    /// 1900-03-01: earlier dates fall before Excel's phantom leap day and are written as text.
    private static let firstSafeDay = days(year: 1900, month: 3, day: 1)
    private static let lastDay = days(year: 9999, month: 12, day: 31)
    static let microsecondsPerDay: Int64 = 86_400_000_000

    /// A date and time parsed from database text.
    struct Moment: Equatable {
        var days: Int
        var microseconds: Int64
    }

    /// The 1900-system serial number of a moment, or nil when Excel cannot show it as a date.
    static func serial(_ moment: Moment) -> Double? {
        guard moment.days >= firstSafeDay, moment.days <= lastDay else { return nil }
        return Double(moment.days - epoch1900) + Double(moment.microseconds) / Double(microsecondsPerDay)
    }

    /// Day count and microseconds of the day for a serial number of either date system.
    static func moment(serial: Double, date1904: Bool) -> Moment? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        // The fraction alone keeps every bit of the time of day. Round to the finest decimal step the double can
        // tell apart at this size (1 µs before 2079), so its noise does not show up as stray digits.
        let whole = serial.rounded(.down)
        var step: Int64 = 1
        while Double(step) < serial.ulp * Double(microsecondsPerDay), step < 1_000_000 { step *= 10 }
        var micros = Int64(((serial - whole) * Double(microsecondsPerDay)).rounded())
        micros = (micros + step / 2) / step * step
        var day = Int(whole)
        if micros >= microsecondsPerDay {
            day += 1
            micros -= microsecondsPerDay
        }
        if date1904 {
            day += epoch1904
        } else if day >= 61 {
            day += epoch1900
        } else if day == 60 {
            // The 1900-02-29 that never was.
            day = days(year: 1900, month: 2, day: 28)
        } else {
            day += epoch1900 + 1
        }
        return Moment(days: day, microseconds: micros)
    }

    // MARK: Database text

    /// `YYYY-MM-DD`, optionally followed by `T` or a space and a time; a trailing zone offset is ignored,
    /// so the wall clock time shown by the database is what the spreadsheet shows.
    static func parseDateTime(_ text: String) -> Moment? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 10, let date = parseDate(bytes[0..<10]) else { return nil }
        if bytes.count == 10 { return Moment(days: date, microseconds: 0) }
        guard bytes[10] == 0x20 || bytes[10] == 0x54, let time = parseTime(bytes[11...], allowZone: true) else { return nil }
        return Moment(days: date, microseconds: time)
    }

    static func parseDate(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10 else { return nil }
        return parseDate(bytes[0..<10])
    }

    /// Microseconds of the day for `HH:MM[:SS[.ffffff]]`, with an optional zone offset after it.
    static func parseTimeOfDay(_ text: String) -> Int64? {
        parseTime(Array(text.utf8)[...], allowZone: true)
    }

    private static func number(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    private static func parseDate(_ bytes: ArraySlice<UInt8>) -> Int? {
        let start = bytes.startIndex
        guard bytes[start + 4] == 0x2D, bytes[start + 7] == 0x2D,
              let year = number(bytes[start..<start + 4]), let month = number(bytes[start + 5..<start + 7]), let day = number(bytes[start + 8..<start + 10]),
              (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year) else { return nil }
        return days(year: year, month: month, day: day)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func parseTime(_ bytes: ArraySlice<UInt8>, allowZone: Bool) -> Int64? {
        var index = bytes.startIndex
        func two() -> Int? {
            guard index + 2 <= bytes.endIndex, let value = number(bytes[index..<index + 2]) else { return nil }
            index += 2
            return value
        }
        guard let hour = two(), hour < 24, index < bytes.endIndex, bytes[index] == 0x3A else { return nil }
        index += 1
        guard let minute = two(), minute < 60 else { return nil }
        var second = 0
        var fraction: Int64 = 0
        if index < bytes.endIndex, bytes[index] == 0x3A {
            index += 1
            guard let value = two(), value < 60 else { return nil }
            second = value
            if index < bytes.endIndex, bytes[index] == 0x2E {
                index += 1
                var digits = 0
                while index < bytes.endIndex, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                    if digits < 6 { fraction = fraction * 10 + Int64(bytes[index] - 0x30) }
                    digits += 1
                    index += 1
                }
                guard digits > 0 else { return nil }
                for _ in min(digits, 6)..<6 { fraction *= 10 }
            }
        }
        if index < bytes.endIndex {
            // A zone: Z, +HH, +HHMM or +HH:MM, possibly after a space.
            guard allowZone else { return nil }
            var zone = bytes[index...]
            if zone.first == 0x20 { zone = zone.dropFirst() }
            guard let sign = zone.first else { return nil }
            if sign == 0x5A {
                guard zone.count == 1 else { return nil }
            } else {
                guard sign == 0x2B || sign == 0x2D else { return nil }
                let rest = zone.dropFirst().filter { $0 != 0x3A }
                guard [2, 4, 6].contains(rest.count), number(rest[...]) != nil else { return nil }
            }
        }
        return (Int64(hour) * 3600 + Int64(minute) * 60 + Int64(second)) * 1_000_000 + fraction
    }

    // MARK: Formatting

    static func dateText(days: Int) -> String {
        let date = civil(days: days)
        return pad(date.year, 4) + "-" + pad(date.month, 2) + "-" + pad(date.day, 2)
    }

    /// `HH:MM:SS`, with up to six fraction digits when there is a fraction (trailing zeros dropped).
    static func timeText(microseconds: Int64) -> String {
        let seconds = Int(microseconds / 1_000_000)
        var text = pad(seconds / 3600, 2) + ":" + pad(seconds / 60 % 60, 2) + ":" + pad(seconds % 60, 2)
        let fraction = microseconds % 1_000_000
        if fraction > 0 {
            var digits = pad(Int(fraction), 6)
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return text
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}

/// Cell references and the string escapes of Office Open XML spreadsheets.
enum XLSXText {
    /// `A`, `B`, … `Z`, `AA`, … for a zero-based column index.
    static func columnLetters(_ index: Int) -> String {
        var number = index + 1
        var letters: [Character] = []
        while number > 0 {
            let remainder = (number - 1) % 26
            letters.append(Character(UnicodeScalar(UInt8(65 + remainder))))
            number = (number - 1) / 26
        }
        return String(letters.reversed())
    }

    /// Zero-based column index of a reference such as `C7`, or nil when it has no letters.
    static func columnIndex(ofReference reference: String) -> Int? {
        var value = 0
        var sawLetter = false
        for byte in reference.utf8 {
            switch byte {
            case 0x41...0x5A: value = value * 26 + Int(byte - 0x40)
            case 0x61...0x7A: value = value * 26 + Int(byte - 0x60)
            default:
                return sawLetter ? value - 1 : nil
            }
            sawLetter = true
        }
        return sawLetter ? value - 1 : nil
    }

    /// Text for element content: XML escapes, carriage returns as character references (XML readers turn a
    /// literal one into a line feed), and characters XML cannot hold as `_xHHHH_`, the way Excel writes them.
    /// A literal `_xHHHH_` gets its underscore escaped so it reads back unchanged.
    static func escapeContent(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": out += "&#13;"
            case "\t", "\n": out.unicodeScalars.append(scalar)
            case "_" where looksLikeEscape(scalars, at: index):
                out += "_x005F_"
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
                    out += "_x" + String(format: "%04X", scalar.value) + "_"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
            index += 1
        }
        return out
    }

    /// Text for an attribute value in double quotes.
    static func escapeAttribute(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case _ where scalar.value < 0x20: out += " "
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || ("A"..."F").contains(scalar) || ("a"..."f").contains(scalar)
    }

    private static func looksLikeEscape(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + 6 < scalars.count, scalars[index + 1] == "x" || scalars[index + 1] == "X", scalars[index + 6] == "_" else { return false }
        return (2...5).allSatisfy { isHex(scalars[index + $0]) }
    }

    /// Undoes `_xHHHH_` escapes in text read from a workbook.
    static func unescape(_ text: String) -> String {
        guard text.contains("_x") || text.contains("_X") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "_", looksLikeEscape(scalars, at: index),
               let value = UInt32(String(String.UnicodeScalarView(scalars[index + 2...index + 5])), radix: 16),
               let decoded = Unicode.Scalar(value) {
                out.append(decoded)
                index += 7
                continue
            }
            out.append(scalars[index])
            index += 1
        }
        return String(out)
    }
}
