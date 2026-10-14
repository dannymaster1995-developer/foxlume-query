import Foundation

/// Where the caret sits in MongoDB shell text; decides what is offered (spec 8.3).
public enum MongoCompletionPosition: Equatable, Sendable {
    case statementStart
    /// The word after a shell command at statement start: `show |` (what to list) or `use |` (a database).
    case shellArgument(command: String)
    /// `db.|`
    case databaseMember
    /// `db.orders.|`; dotted names keep their dots (`db.my.coll.|` is `my.coll`).
    case collectionMethod(collection: String)
    /// `db.orders.find({}).|`
    case cursorMethod
    case filterDocument(collection: String?)
    case projectionDocument(collection: String?)
    /// Inserted or replacement documents and index keys.
    case plainDocument(collection: String?)
    /// Keys that can only be field names: `$sort`, `$unset` and the keys of `$project` / `$addFields` / `$set`.
    case fieldNames(collection: String?)
    /// The update argument of updateOne/updateMany/findOneAndUpdate. `insideOperator` once inside `{ $set: { |`,
    /// where field paths are offered too.
    case updateDocument(collection: String?, insideOperator: Bool)
    case updatePipelineStage(collection: String?)
    case pipelineStage(collection: String?)
    case stageExpression(collection: String?)

    /// Short tag kept in the refilter state.
    var tag: String {
        switch self {
        case .statementStart: return "statementStart"
        case .shellArgument: return "shellArgument"
        case .databaseMember: return "databaseMember"
        case .collectionMethod: return "collectionMethod"
        case .cursorMethod: return "cursorMethod"
        case .filterDocument: return "filterDocument"
        case .projectionDocument: return "projectionDocument"
        case .plainDocument: return "plainDocument"
        case .fieldNames: return "fieldNames"
        case .updateDocument: return "updateDocument"
        case .updatePipelineStage: return "updatePipelineStage"
        case .pipelineStage: return "pipelineStage"
        case .stageExpression: return "stageExpression"
        }
    }

    /// Positions that open automatically with nothing typed: right after `db.`, `db.c.`, `).` and `[{` (spec 8.5),
    /// and the short closed list after `show ` / `use `.
    var opensWithoutPrefix: Bool {
        switch self {
        case .databaseMember, .collectionMethod, .cursorMethod, .pipelineStage, .updatePipelineStage, .shellArgument: return true
        default: return false
        }
    }

    /// Positions inside a document or array argument, with the collection they read.
    var documentCollection: String?? {
        switch self {
        case .filterDocument(let collection), .projectionDocument(let collection), .plainDocument(let collection),
             .fieldNames(let collection), .updateDocument(let collection, _), .updatePipelineStage(let collection),
             .pipelineStage(let collection), .stageExpression(let collection):
            return .some(collection)
        default:
            return nil
        }
    }
}

/// The token at the caret and the position it is in.
struct MongoCompletionAnalysis: Equatable {
    /// UTF-16 range an accepted item replaces: token start to caret.
    var tokenRange: NSRange
    var token: String
    /// Nil when completion is suppressed (comment, plain string argument, unsupported call, `aggregate` without an array).
    var position: MongoCompletionPosition?
    /// The token sits inside a string literal (a `"$field"` reference inside a document).
    var inString: Bool
    /// Inside a document, the dotted path right before `.` and the token (`address` in `{"address.ci|`,
    /// `$items` in `"$items.sk|`); empty when no name precedes the dot (`ISODate().|`). Nil without a dot.
    var fieldQualifier: String? = nil
}

/// One left-to-right scan of the statement before the token: comments, strings and a stack of open brackets
/// (spec 8.1-8.3), plus what each call returns so `db.getCollection("x").` chains resolve.
enum MongoCompletionScanner {
    /// Text further back than this is not scanned; longer documents start at a command line inside this distance.
    static let window = 1_000_000
    /// Command lines tried as the statement start before falling back to the window start.
    static let statementStartAttempts = 4

    /// What the expression before a `.` or `(` stands for.
    enum Value: Equatable {
        case database
        case collection(String)
        case other
    }

    struct Frame {
        enum Kind { case paren, brace, bracket }
        var kind: Kind
        var open: Int
        /// For `(`: the identifier right before it and what it is called on (`db.orders` in `db.orders.find(`).
        var callee: String?
        var receiver: Value?
        /// For `(`: commas seen at this level.
        var argumentIndex = 0
        /// For `{` and `[`: the operator key this bracket is the value of (`$match` for the inner brace of
        /// `{$match: {`); nil for field names.
        var key: String?
        /// For `{`: the operator key typed last at this level, and whether a `:` has been typed since the last `,`.
        var lastKey: String?
        var expectsValue = false

        /// The collection a method is called on; nil when unknown (`db.getCollection(name).find(`).
        var collection: String? {
            if case .collection(let name)? = receiver, !name.isEmpty { return name }
            return nil
        }
    }

    // MARK: - Identifier characters

    /// Letters, digits and combining marks of any script, and `_`.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .connectorPunctuation:
            return true
        default:
            return false
        }
    }

    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The scalar ending at `end` and its UTF-16 length; nil for a lone surrogate.
    private static func scalar(_ units: [UInt16], endingAt end: Int, lowerBound: Int) -> (Unicode.Scalar, Int)? {
        let c = units[end - 1]
        if UTF16.isTrailSurrogate(c) {
            guard end - 2 >= lowerBound, UTF16.isLeadSurrogate(units[end - 2]) else { return nil }
            return pair(units[end - 2], c).map { ($0, 2) }
        }
        guard let scalar = Unicode.Scalar(c) else { return nil }
        return (scalar, 1)
    }

    private static func pair(_ lead: UInt16, _ trail: UInt16) -> Unicode.Scalar? {
        Unicode.Scalar(0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
    }

    private static func scalar(_ units: [UInt16], startingAt start: Int) -> (Unicode.Scalar, Int)? {
        let c = units[start]
        if UTF16.isLeadSurrogate(c) {
            guard start + 1 < units.count, UTF16.isTrailSurrogate(units[start + 1]) else { return nil }
            return pair(c, units[start + 1]).map { ($0, 2) }
        }
        guard let scalar = Unicode.Scalar(c) else { return nil }
        return (scalar, 1)
    }

    /// Start of the run of word characters (and `$` when `dollars`) that ends at `end`. A run never starts with a
    /// combining mark, which belongs to the character before it.
    static func wordStart(_ units: [UInt16], before end: Int, lowerBound: Int = 0, dollars: Bool) -> Int {
        var start = end
        while start > lowerBound {
            let c = units[start - 1]
            if c < 0x80 {
                guard (dollars && c == 0x24) || isWordScalar(Unicode.Scalar(UInt8(c))) else { break }
                start -= 1
                continue
            }
            guard let (scalar, width) = scalar(units, endingAt: start, lowerBound: lowerBound), isWordScalar(scalar) else { break }
            start -= width
        }
        while start < end, let (scalar, width) = scalar(units, startingAt: start), isMark(scalar) { start += width }
        return start
    }

    /// Token start: back over word characters, then over at most two `$` (`$gt`, `$$NOW`). Spec 8.1 names ASCII
    /// only; other letters count too so sampled names such as `név` can be typed.
    static func tokenStart(_ units: [UInt16], caret: Int) -> Int {
        var start = wordStart(units, before: caret, dollars: false)
        var sigils = 0
        while start > 0, sigils < 2, units[start - 1] == 0x24 {
            start -= 1
            sigils += 1
        }
        return start
    }

    /// Whether `token` is something the token rule could have produced (used to validate a live re-filter token).
    static func isToken(_ token: String) -> Bool {
        let units = Array(token.utf16)
        return tokenStart(units, caret: units.count) == 0
    }

    // MARK: - Analysis

    static func analyze(_ text: String, caret rawCaret: Int) -> MongoCompletionAnalysis {
        let units = Array(text.utf16)
        let caret = min(max(0, rawCaret), units.count)
        let start = tokenStart(units, caret: caret)
        let token = String(decoding: units[start..<caret], as: UTF16.self)
        let range = NSRange(location: start, length: caret - start)

        // The nearest line that begins a command usually starts the statement; when the scan from it closes a
        // bracket it never opened (or ends a comment it never began), that line sat inside an earlier statement.
        var candidates = commandLineStarts(units, tokenStart: start)
        candidates.append(scanStart(units, tokenStart: start))
        var scan = Scan(units: units, lowerBound: 0)
        var state = (inString: false, inComment: false, nested: false)
        for (attempt, lowerBound) in candidates.enumerated() {
            scan = Scan(units: units, lowerBound: lowerBound)
            state = scan.run(to: start, strict: attempt < candidates.count - 1)
            if !state.nested { break }
        }
        var analysis = MongoCompletionAnalysis(tokenRange: range, token: token, position: nil, inString: state.inString)
        guard !state.inComment else { return analysis }
        if scan.frames.isEmpty {
            analysis.position = state.inString ? nil : scan.topLevelPosition(tokenStart: start)
            return analysis
        }
        analysis.position = nestedPosition(scan.frames, inString: state.inString)
        if start > scan.lowerBound, units[start - 1] == 0x2E {
            let dot = start - 1
            let qualifierStart = wordStart(units, before: dot, lowerBound: scan.lowerBound, dollars: true)
            // Keep the whole dotted path: `$$ROOT.items.` is `$$ROOT.items`.
            var pathStart = qualifierStart
            while pathStart > scan.lowerBound + 1, units[pathStart - 1] == 0x2E {
                let segmentStart = wordStart(units, before: pathStart - 1, lowerBound: scan.lowerBound, dollars: true)
                guard segmentStart < pathStart - 1 else { break }
                pathStart = segmentStart
            }
            analysis.fieldQualifier = String(decoding: units[pathStart..<dot], as: UTF16.self)
        }
        return analysis
    }

    /// The document start, or for very long documents the first top-level command line inside the window, so a
    /// statement thousands of characters long still has its opening `db.<c>.<method>(` in view.
    static func scanStart(_ units: [UInt16], tokenStart start: Int) -> Int {
        guard start > window else { return 0 }
        let floor = start - window
        var lineStart = floor
        while lineStart < start, units[lineStart - 1] != 0x0A { lineStart += 1 }
        guard lineStart < start else { return floor }
        var candidate = lineStart
        while candidate < start {
            if startsCommand(units, at: candidate, before: start) { return candidate }
            while candidate < start, units[candidate] != 0x0A { candidate += 1 }
            candidate += 1
        }
        return lineStart
    }

    /// Starts of the lines that begin a shell command (`db.`, `use `, `show `), nearest first, from the token's
    /// own line back to the window edge, at most `statementStartAttempts`.
    static func commandLineStarts(_ units: [UInt16], tokenStart start: Int) -> [Int] {
        let floor = max(0, start - window)
        var starts: [Int] = []
        var lineStart = start
        while lineStart > floor, units[lineStart - 1] != 0x0A { lineStart -= 1 }
        while starts.count < statementStartAttempts {
            if startsCommand(units, at: lineStart, before: start) { starts.append(lineStart) }
            guard lineStart > floor else { break }
            lineStart -= 1
            while lineStart > floor, units[lineStart - 1] != 0x0A { lineStart -= 1 }
        }
        return starts
    }

    private static let commandWords: [[UInt16]] = ["db.", "use ", "show "].map { Array($0.utf16) }

    private static func startsCommand(_ units: [UInt16], at position: Int, before end: Int) -> Bool {
        var cursor = position
        while cursor < end, units[cursor] == 0x20 || units[cursor] == 0x09 { cursor += 1 }
        return commandWords.contains { word in
            cursor + word.count <= units.count && units[cursor..<(cursor + word.count)].elementsEqual(word)
        }
    }

    // MARK: - Scan

    private struct Scan {
        let units: [UInt16]
        let lowerBound: Int
        var frames: [Frame] = []
        /// Comment end (exclusive) to comment start, for walking back over comments.
        var comments: [Int: Int] = [:]
        /// `)` index to what the call returned, kept only for calls that return a database or a collection.
        var calls: [Int: Value] = [:]
        /// The last string literal closed: its opening and closing quote indices.
        var lastString: (open: Int, close: Int)?

        init(units: [UInt16], lowerBound: Int) {
            self.units = units
            self.lowerBound = lowerBound
        }

        /// Scans `lowerBound..<end`. When `strict`, stops early and reports `nested` on a closer with nothing open
        /// or a `*/` outside a comment: the scan began inside something.
        mutating func run(to end: Int, strict: Bool) -> (inString: Bool, inComment: Bool, nested: Bool) {
            var index = lowerBound
            while index < end {
                let c = units[index]
                switch c {
                case 0x2F where index + 1 < units.count && units[index + 1] == 0x2F:
                    let commentStart = index
                    index += 2
                    while index < end, units[index] != 0x0A { index += 1 }
                    guard index < end else { return (false, true, false) }
                    comments[index] = commentStart
                    continue
                case 0x2F where index + 1 < units.count && units[index + 1] == 0x2A:
                    let commentStart = index
                    index += 2
                    while index < end, !(units[index] == 0x2A && index + 1 < units.count && units[index + 1] == 0x2F) { index += 1 }
                    guard index < end else { return (false, true, false) }
                    index += 2
                    comments[index] = commentStart
                    continue
                case 0x2A where strict && index + 1 < units.count && units[index + 1] == 0x2F:
                    return (false, false, true)
                case 0x22, 0x27, 0x60:
                    let quoteStart = index
                    index += 1
                    while index < end {
                        let u = units[index]
                        if u == 0x5C {
                            index += 2
                        } else if u == c {
                            break
                        } else if u == 0x0A, c != 0x60 {
                            // Quotes and apostrophes cannot span lines in JavaScript; template literals can.
                            break
                        } else {
                            index += 1
                        }
                    }
                    guard index < end else { return (true, false, false) }
                    if units[index] == c { lastString = (quoteStart, index) }
                case 0x28:
                    frames.append(callFrame(paren: index))
                case 0x7B:
                    frames.append(Frame(kind: .brace, open: index, key: valueKey()))
                case 0x5B:
                    frames.append(Frame(kind: .bracket, open: index, key: valueKey()))
                case 0x29, 0x7D, 0x5D:
                    guard let frame = frames.popLast() else {
                        if strict { return (false, false, true) }
                        break
                    }
                    if c == 0x29, frame.kind == .paren, let value = callResult(frame, close: index) {
                        calls[index] = value
                    }
                case 0x2C:
                    guard let last = frames.indices.last else { break }
                    switch frames[last].kind {
                    case .paren:
                        frames[last].argumentIndex += 1
                    case .brace:
                        frames[last].lastKey = nil
                        frames[last].expectsValue = false
                    case .bracket:
                        break
                    }
                case 0x3A:
                    guard let last = frames.indices.last, frames[last].kind == .brace else { break }
                    frames[last].lastKey = keyBefore(colon: index)
                    frames[last].expectsValue = true
                default:
                    break
                }
                index += 1
            }
            return (false, false, false)
        }

        // MARK: Looking back

        /// Moves back from `end` over whitespace, newlines and comments.
        func skipTrivia(back end: Int) -> Int {
            var index = end
            while index > lowerBound {
                if let commentStart = comments[index] {
                    index = commentStart
                    continue
                }
                let c = units[index - 1]
                guard c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D else { break }
                index -= 1
            }
            return index
        }

        func wordStart(before end: Int, dollars: Bool) -> Int {
            MongoCompletionScanner.wordStart(units, before: end, lowerBound: lowerBound, dollars: dollars)
        }

        /// What the member chain ending at `end` stands for: `db`, `db.orders`, `db.getCollection("x")`,
        /// `db.getSiblingDB("y").orders`; `.other` for any other chain; nil when there is no chain.
        /// Whitespace, newlines and comments may sit around the dots (`db.orders\n  .find(`).
        func value(endingAt end: Int) -> Value? {
            var segments: [String] = []
            var position = skipTrivia(back: end)
            var base: Value?
            while true {
                let start = wordStart(before: position, dollars: true)
                guard start < position else {
                    if position > lowerBound, units[position - 1] == 0x29 {
                        base = calls[position - 1] ?? .other
                    } else if segments.isEmpty {
                        return nil
                    } else {
                        return .other
                    }
                    break
                }
                segments.insert(String(decoding: units[start..<position], as: UTF16.self), at: 0)
                let beforeName = skipTrivia(back: start)
                guard beforeName > lowerBound, units[beforeName - 1] == 0x2E else { break }
                position = skipTrivia(back: beforeName - 1)
            }
            var value: Value
            if let base {
                value = base
            } else {
                guard segments.first == "db" else { return .other }
                segments.removeFirst()
                value = .database
            }
            for segment in segments {
                switch value {
                case .database: value = .collection(segment)
                case .collection(let name): value = .collection(name.isEmpty ? "" : name + "." + segment)
                case .other: return .other
                }
            }
            return value
        }

        /// A `(` frame with the identifier before it (spaces allowed) and what that identifier is called on.
        func callFrame(paren: Int) -> Frame {
            var frame = Frame(kind: .paren, open: paren)
            let end = skipTrivia(back: paren)
            let start = wordStart(before: end, dollars: true)
            guard start < end, let first = MongoCompletionScanner.scalar(units, startingAt: start)?.0,
                  first.properties.generalCategory != .decimalNumber else { return frame }
            frame.callee = String(decoding: units[start..<end], as: UTF16.self)
            let beforeName = skipTrivia(back: start)
            if beforeName > lowerBound, units[beforeName - 1] == 0x2E {
                frame.receiver = value(endingAt: beforeName - 1)
            }
            return frame
        }

        /// `db.getCollection("x")` returns collection `x` (an unnamed one for a non-literal argument),
        /// `db.getSiblingDB("y")` a database; nil for anything else.
        func callResult(_ frame: Frame, close: Int) -> Value? {
            guard frame.receiver == .database else { return nil }
            switch frame.callee {
            case "getCollection": return .collection(soleStringArgument(open: frame.open, close: close) ?? "")
            case "getSiblingDB": return .database
            default: return nil
            }
        }

        /// The text of the only argument between `open` and `close` when it is one string literal.
        func soleStringArgument(open: Int, close: Int) -> String? {
            guard let string = lastString, string.open > open, string.close < close else { return nil }
            let blank: (UInt16) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
            guard units[(open + 1)..<string.open].allSatisfy(blank), units[(string.close + 1)..<close].allSatisfy(blank) else { return nil }
            return decodedString(open: string.open, close: string.close)
        }

        func decodedString(open: Int, close: Int) -> String {
            var content: [UInt16] = []
            var index = open + 1
            while index < close {
                if units[index] == 0x5C, index + 1 < close { index += 1 }
                content.append(units[index])
                index += 1
            }
            return String(decoding: content, as: UTF16.self)
        }

        /// The operator key before a `:` (`$match`, `"$unset"`). Field names are left out: only operators steer
        /// what is offered, and documents with thousands of keys should not cost a string each.
        func keyBefore(colon: Int) -> String? {
            let end = skipTrivia(back: colon)
            guard end > lowerBound else { return nil }
            if let string = lastString, string.close == end - 1 {
                guard string.close > string.open + 1, units[string.open + 1] == 0x24 else { return nil }
                return decodedString(open: string.open, close: string.close)
            }
            let start = wordStart(before: end, dollars: true)
            guard start < end, units[start] == 0x24 else { return nil }
            return String(decoding: units[start..<end], as: UTF16.self)
        }

        /// The key a new `{` or `[` is the value of, when it opens right after `key:` in a document.
        func valueKey() -> String? {
            guard let top = frames.last, top.kind == .brace, top.expectsValue else { return nil }
            return top.lastKey
        }

        // MARK: Top level

        func topLevelPosition(tokenStart start: Int) -> MongoCompletionPosition? {
            guard start > lowerBound, units[start - 1] == 0x2E else {
                return MongoCompletionScanner.shellArgument(units, tokenStart: start, lowerBound: lowerBound) ?? .statementStart
            }
            let dot = start - 1
            switch value(endingAt: dot) {
            case .database?:
                return .databaseMember
            case .collection(let name)?:
                return .collectionMethod(collection: name)
            case .other?:
                // A call result is a cursor (`find({}).`, also chained on the next line); other member access
                // (`Math.`, `x.y.`) has nothing to offer.
                let tail = skipTrivia(back: dot)
                return tail > lowerBound && units[tail - 1] == 0x29 ? .cursorMethod : nil
            case nil:
                return nil
            }
        }
    }

    /// `show |` and `use |`: the line (or the text after the last `;`) is just the command and whitespace.
    private static func shellArgument(_ units: [UInt16], tokenStart start: Int, lowerBound: Int) -> MongoCompletionPosition? {
        var lineStart = start
        while lineStart > lowerBound, units[lineStart - 1] != 0x0A, units[lineStart - 1] != 0x3B { lineStart -= 1 }
        let before = String(decoding: units[lineStart..<start], as: UTF16.self)
        guard before.last?.isWhitespace == true else { return nil }
        let words = before.split(whereSeparator: \.isWhitespace)
        guard words.count == 1, words[0] == "show" || words[0] == "use" else { return nil }
        return .shellArgument(command: String(words[0]))
    }

    // MARK: - Nested positions

    private static func nestedPosition(_ frames: [Frame], inString: Bool) -> MongoCompletionPosition? {
        guard let callIndex = frames.lastIndex(where: { $0.kind == .paren && $0.callee != nil }) else {
            return inString ? nil : .statementStart
        }
        let call = frames[callIndex]
        let nested = frames[(callIndex + 1)...]
        // A string typed straight into the call parentheses is a value, not a document.
        if inString, nested.isEmpty { return nil }
        let collection = call.collection
        switch call.callee ?? "" {
        case "find", "findOne":
            switch call.argumentIndex {
            case 0: return filterPosition(nested, collection: collection)
            case 1: return .projectionDocument(collection: collection)
            default: return nil
            }
        case "countDocuments", "deleteOne", "deleteMany", "findOneAndDelete":
            return call.argumentIndex == 0 ? filterPosition(nested, collection: collection) : nil
        case "distinct":
            return filterPosition(nested, collection: collection)
        case "updateOne", "updateMany", "findOneAndUpdate":
            switch call.argumentIndex {
            case 0:
                return filterPosition(nested, collection: collection)
            case 1:
                if nested.first?.kind == .bracket {
                    return pipelinePosition(nested.dropFirst(), collection: collection, inString: inString, update: true)
                }
                let braces = nested.filter { $0.kind == .brace }.count
                return .updateDocument(collection: collection, insideOperator: braces >= 2)
            default:
                return nil
            }
        case "replaceOne", "findOneAndReplace":
            switch call.argumentIndex {
            case 0: return filterPosition(nested, collection: collection)
            case 1: return .plainDocument(collection: collection)
            default: return nil
            }
        case "insertOne", "insertMany", "createIndex", "createIndexes", "dropIndex", "hideIndex", "unhideIndex":
            return .plainDocument(collection: collection)
        case "aggregate":
            guard nested.first?.kind == .bracket else { return nil }
            return pipelinePosition(nested.dropFirst(), collection: collection, inString: inString, update: false)
        default:
            return nil
        }
    }

    /// A query filter; inside `$expr` the aggregation expression language applies instead.
    private static func filterPosition(_ frames: ArraySlice<Frame>, collection: String?) -> MongoCompletionPosition {
        frames.contains { $0.key == "$expr" } ? .stageExpression(collection: collection) : .filterDocument(collection: collection)
    }

    /// `frames` are the brackets inside a pipeline's `[`. Directly in a stage document: stage names, or for a value
    /// (`{$unwind: "$it|`) field references. Inside a stage, the stage decides: `$match` is a filter, `$sort` and
    /// `$unset` take field names, `$project` / `$addFields` / `$set` field names as keys and expressions as values.
    private static func pipelinePosition(_ frames: ArraySlice<Frame>, collection: String?, inString: Bool, update: Bool) -> MongoCompletionPosition? {
        let stageNames: MongoCompletionPosition = update ? .updatePipelineStage(collection: collection) : .pipelineStage(collection: collection)
        guard let document = frames.first else { return inString ? nil : stageNames }
        guard document.kind == .brace else { return nil }
        let body = frames.dropFirst()
        guard let inner = body.first else {
            guard document.expectsValue else { return stageNames }
            return document.lastKey == "$unset" ? .fieldNames(collection: collection) : .stageExpression(collection: collection)
        }
        let atKey = body.count == 1 && inner.kind == .brace && !inner.expectsValue
        switch inner.key ?? "" {
        case "$match":
            return filterPosition(body, collection: collection)
        case "$sort":
            return atKey ? .fieldNames(collection: collection) : nil
        case "$unset":
            return .fieldNames(collection: collection)
        case "$project", "$addFields", "$set":
            return atKey ? .fieldNames(collection: collection) : .stageExpression(collection: collection)
        default:
            return .stageExpression(collection: collection)
        }
    }
}
