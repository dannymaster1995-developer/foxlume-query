import Foundation

/// Where the statements of an editor's text are, split the way Run Statement splits them. Drives the band behind
/// the statement at the caret and Run Statement and Move to Next. Offsets are UTF-16 units, entries are sorted.
public struct StatementMap: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// The statement as split, plus the `;` that ends it.
        public var range: NSRange
        /// Where the band starts: the statement's start, or the next line when it starts with a comment that trails
        /// the previous statement on its line (`SELECT 1; -- note`).
        public var bandStart: Int
        /// The first character after the blank lines and comments that open the statement.
        public var codeStart: Int

        public init(range: NSRange, bandStart: Int? = nil, codeStart: Int) {
            self.range = range
            self.bandStart = bandStart ?? range.location
            self.codeStart = codeStart
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public init(text: String, language: QueryLanguage) {
        let units = Array(text.utf16)
        var previousEnd: Int?
        entries = language.split(text).map { statement in
            let range = statement.range
            var end = NSMaxRange(range)
            var index = end
            while index < units.count, Self.isWhitespace(units[index]) { index += 1 }
            if index < units.count, units[index] == 0x3B { end = index + 1 } // ;
            let codeStart = Self.skipLeadingComments(units, from: range.location, to: NSMaxRange(range), language: language)
            var bandStart = range.location
            if let previousEnd, !units[previousEnd..<range.location].contains(0x0A),
               let newline = units[range.location..<codeStart].firstIndex(of: 0x0A) {
                bandStart = newline + 1
                while bandStart < codeStart, Self.isWhitespace(units[bandStart]) { bandStart += 1 }
            }
            previousEnd = end
            return Entry(range: NSRange(location: range.location, length: end - range.location), bandStart: bandStart, codeStart: codeStart)
        }
    }

    public var count: Int { entries.count }

    /// The statement Run Statement picks for a caret at `location`: the one containing it (both ends included),
    /// else the closest one before it, else the first. Matches `QueryLanguage.statement(at:in:)`.
    public func runIndex(at location: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        guard let index = lastIndex(startingAtOrBefore: location) else { return 0 }
        return index
    }

    /// The range of the band: the statement whose range (with its `;`) holds the caret. Nil when the text holds
    /// fewer than two statements or the caret sits between statements, a comment trailing the previous one included.
    public func bandRange(at caret: Int) -> NSRange? {
        guard entries.count >= 2, let index = lastIndex(startingAtOrBefore: caret) else { return nil }
        let entry = entries[index]
        let end = NSMaxRange(entry.range)
        guard caret >= entry.bandStart, caret <= end else { return nil }
        return NSRange(location: entry.bandStart, length: end - entry.bandStart)
    }

    /// Where Run Statement and Move to Next puts the caret after running the statement at `selection`: the start of
    /// the next statement's code, past blank lines and comments. Nil at the last statement.
    public func nextStatementStart(after selection: NSRange) -> Int? {
        // A selection that ends where the next statement begins (a whole line selected) still belongs before it.
        let location = selection.length > 0 ? max(selection.location, NSMaxRange(selection) - 1) : selection.location
        guard let index = runIndex(at: location), index + 1 < entries.count else { return nil }
        return entries[index + 1].codeStart
    }

    /// The map after an edit, until the text is split again: positions after the edit move by its change in
    /// length, a statement the edit touches grows or shrinks with it. `editedRange` is the range of the new text.
    public func shifted(byEditing editedRange: NSRange, changeInLength delta: Int) -> StatementMap {
        let start = editedRange.location
        let oldEnd = start + editedRange.length - delta
        let newEnd = NSMaxRange(editedRange)
        func lower(_ position: Int) -> Int {
            position < start ? position : (position >= oldEnd ? position + delta : start)
        }
        func upper(_ position: Int) -> Int {
            position < start ? position : (position >= oldEnd ? position + delta : newEnd)
        }
        return StatementMap(entries: entries.map { entry in
            let location = lower(entry.range.location)
            let end = max(location, upper(NSMaxRange(entry.range)))
            let codeStart = min(max(location, lower(entry.codeStart)), end)
            return Entry(range: NSRange(location: location, length: end - location),
                         bandStart: min(max(location, lower(entry.bandStart)), codeStart), codeStart: codeStart)
        })
    }

    /// Binary search for the last entry that starts at or before `location`.
    private func lastIndex(startingAtOrBefore location: Int) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].range.location <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    /// Skips whitespace and the comments the language's splitter knows; executable MySQL comments (`/*! … */`) are code.
    private static func skipLeadingComments(_ units: [UInt16], from start: Int, to end: Int, language: QueryLanguage) -> Int {
        var index = start
        while index < end {
            let c = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if isWhitespace(c) {
                index += 1
                continue
            }
            switch language {
            case .sql(let family):
                if c == 0x2D, next == 0x2D { // --
                    index = SQLStatementSplitter.skipLine(units, from: index)
                } else if c == 0x23, family == .mysql { // #
                    index = SQLStatementSplitter.skipLine(units, from: index)
                } else if c == 0x2F, next == 0x2A, !(family == .mysql && isExecutableComment(units, at: index)) { // /*
                    index = SQLStatementSplitter.skipBlockComment(units, from: index, nested: family == .postgresql)
                } else {
                    return index
                }
            case .mongo:
                if c == 0x2F, next == 0x2F {
                    index = SQLStatementSplitter.skipLine(units, from: index)
                } else if c == 0x2F, next == 0x2A {
                    index = SQLStatementSplitter.skipBlockComment(units, from: index, nested: false)
                } else {
                    return index
                }
            case .redis:
                return index
            }
        }
        return min(index, end)
    }

    /// `/*!` or `/*M!` at `index`.
    private static func isExecutableComment(_ units: [UInt16], at index: Int) -> Bool {
        guard index + 2 < units.count else { return false }
        if units[index + 2] == 0x21 { return true }
        return units[index + 2] == 0x4D && index + 3 < units.count && units[index + 3] == 0x21
    }
}
