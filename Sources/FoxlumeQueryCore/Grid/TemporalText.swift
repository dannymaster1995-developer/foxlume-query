import Foundation

/// A date or time value as the text a driver returns (`2024-03-05 14:07:09.123456+05:30`), split so a picker can change
/// the date or the clock time while everything else (fractional seconds, time zone, a trailing `BC`) stays exactly as
/// written. No time zone conversion ever happens: the picker shows and sets the wall-clock fields of the text.
public struct TemporalText: Hashable, Sendable {
    public struct Day: Hashable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }
    }

    public struct Clock: Hashable, Sendable {
        public var hour: Int
        public var minute: Int
        public var second: Int

        public init(hour: Int, minute: Int, second: Int) {
            self.hour = hour
            self.minute = minute
            self.second = second
        }
    }

    public var day: Day?
    public var clock: Clock?
    /// `.123456`, or empty.
    public var fraction: String
    /// What followed the clock: a zone such as `+05:30`, `Z` or ` UTC`, and anything after it; kept verbatim.
    public var suffix: String
    /// Between date and time: a space or `T`.
    public var separator: String

    public init(day: Day?, clock: Clock?, fraction: String = "", suffix: String = "", separator: String = " ") {
        self.day = day
        self.clock = clock
        self.fraction = fraction
        self.suffix = suffix
        self.separator = separator
    }

    /// Reads `text` as a value of `kind`; nil when it is not in the ISO-like form drivers return (`infinity`, a MySQL
    /// time past 24 hours, free text).
    public static func parse(_ text: String, kind: TemporalKind) -> TemporalText? {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        var index = 0
        func number(_ digits: ClosedRange<Int>) -> Int? {
            var count = 0
            var value = 0
            while index < characters.count, count < digits.upperBound, let digit = characters[index].wholeNumberValue, characters[index].isASCII {
                value = value * 10 + digit
                index += 1
                count += 1
            }
            return count >= digits.lowerBound ? value : nil
        }
        func expect(_ character: Character) -> Bool {
            guard index < characters.count, characters[index] == character else { return false }
            index += 1
            return true
        }
        var result = TemporalText(day: nil, clock: nil)
        if kind.hasDate {
            guard let year = number(4...6), expect("-"), let month = number(1...2), expect("-"), let day = number(1...2),
                  (1...12).contains(month), (1...31).contains(day) else { return nil }
            result.day = Day(year: year, month: month, day: day)
        }
        if kind.hasTime {
            if kind.hasDate {
                // A timestamp may be written as a bare date; the clock is then midnight.
                guard index < characters.count, characters[index] == " " || characters[index] == "T" else {
                    guard index == characters.count else { return nil }
                    result.clock = Clock(hour: 0, minute: 0, second: 0)
                    return result
                }
                result.separator = String(characters[index])
                index += 1
            }
            guard let hour = number(1...2), expect(":"), let minute = number(2...2), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            var second = 0
            if expect(":") {
                guard let value = number(2...2), (0...60).contains(value) else { return nil }
                second = value
            }
            result.clock = Clock(hour: hour, minute: minute, second: second)
            if index < characters.count, characters[index] == "." {
                var fraction = "."
                index += 1
                while index < characters.count, characters[index].isASCII, characters[index].isNumber {
                    fraction.append(characters[index])
                    index += 1
                }
                result.fraction = fraction
            }
        }
        result.suffix = String(characters[index...])
        // A date column carries nothing after the day except an era.
        if !kind.hasTime, !result.suffix.isEmpty, result.suffix.trimmingCharacters(in: .whitespaces).uppercased() != "BC" { return nil }
        return result
    }

    public var text: String {
        var out = ""
        if let day {
            out += String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        }
        if let clock {
            if day != nil { out += separator }
            out += String(format: "%02d:%02d:%02d", clock.hour, clock.minute, clock.second) + fraction
        }
        return out + suffix
    }

    /// The value with a new day and clock from a picker. The fraction is dropped when the clock changed, since the
    /// picker cannot show it; the zone and anything else after the clock always stay.
    public func replacing(day newDay: Day?, clock newClock: Clock?) -> TemporalText {
        var copy = self
        if let newDay, copy.day != nil { copy.day = newDay }
        if let newClock, copy.clock != nil, newClock != copy.clock {
            copy.clock = newClock
            copy.fraction = ""
        }
        return copy
    }

    /// A fresh value for an empty cell or the Now / Today button: `date` in the given zone's wall clock, written as
    /// the engines accept it. Columns with a time zone get the zone's offset (`+07:00`).
    public static func current(_ kind: TemporalKind, date: Date = Date(), timeZone: TimeZone = .current) -> TemporalText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = Day(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
        let clock = Clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0)
        return TemporalText(
            day: kind.hasDate ? day : nil,
            clock: kind.hasTime ? clock : nil,
            suffix: kind.hasTimeZone ? offsetText(timeZone.secondsFromGMT(for: date)) : ""
        )
    }

    /// `+07:00`, `-03:30`, `+00:00`.
    static func offsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// The wall-clock fields as a `Date` in GMT, for a date picker that also runs in GMT; the year is clamped to what
    /// the picker can show.
    public var pickerDate: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT") ?? .current
        var parts = DateComponents()
        parts.year = min(max(day?.year ?? 2000, 1), 9999)
        parts.month = day?.month ?? 1
        parts.day = day?.day ?? 1
        parts.hour = clock?.hour ?? 0
        parts.minute = clock?.minute ?? 0
        parts.second = min(clock?.second ?? 0, 59)
        return calendar.date(from: parts)
    }

    /// Reads a GMT picker date back into a day and a clock.
    public static func fields(ofPickerDate date: Date) -> (day: Day, clock: Clock) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (Day(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1),
                Clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0))
    }
}
