import Foundation

// MARK: - Cells

/// Converts BSON values to grid cells and edited cells back to BSON with the stored type kept.
enum MongoCellCodec {
    static let maxNestedLength = 10_000
    static let numericTypes: Set<String> = ["FLOAT", "INTEGER", "BIGINT", "decimal"]

    /// The column type a value votes for. Nil for null, which does not vote.
    static func typeName(_ value: BSONValue) -> String? {
        switch value {
        case .null: return nil
        case .double: return "FLOAT"
        case .int32: return "INTEGER"
        case .int64: return "BIGINT"
        case .decimal128: return "decimal"
        case .string, .symbol: return "VARCHAR"
        case .bool: return "BOOLEAN"
        case .date: return "TIMESTAMP"
        case .objectId: return "ObjectId"
        case let .binary(subtype, data): return subtype == 4 && data.count == 16 ? "UUID" : "BLOB"
        case .document, .array, .undefined, .regex, .dbPointer, .javascript, .javascriptWithScope, .timestamp, .minKey, .maxKey:
            return "JSON"
        }
    }

    /// Majority vote over non-null values; ties go to the type seen first. All-null fields are VARCHAR.
    static func voteTypeName<S: Sequence>(_ values: S) -> String? where S.Element == BSONValue {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for value in values {
            guard let name = typeName(value) else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        var best: String?
        for name in order where best == nil || (counts[name] ?? 0) > (counts[best ?? ""] ?? 0) {
            best = name
        }
        return best
    }

    static func cell(_ value: BSONValue?) -> CellValue {
        guard let value else { return .missing }
        switch value {
        case .null: return .null
        case .double(let number): return .text(ExtendedJSON.doubleText(number))
        case .string(let text), .symbol(let text): return .text(text)
        case .document(let document):
            if case .string(let collection)? = document["$ref"], let id = document["$id"], document.count <= 3, document.keys.first == "$ref" {
                var text = "DBRef(\(ExtendedJSON.quoted(collection)), \(MongoShellFormatter.scalar(id))"
                if case .string(let database)? = document["$db"] { text += ", \(ExtendedJSON.quoted(database))" }
                return .text(text + ")")
            }
            return .text(nested(value))
        case .array: return .text(nested(value))
        case let .binary(subtype, data):
            if subtype == 4, data.count == 16 { return .text("UUID(\"\(MongoShellFormatter.uuidText(data))\")") }
            return .bytes(data)
        case .objectId(let id): return .text(id.hex)
        case .bool(let flag): return .text(flag ? "true" : "false")
        case .date(let milliseconds): return .text(ExtendedJSON.isoDateText(milliseconds))
        case .int32(let number): return .text(String(number))
        case .int64(let number): return .text(String(number))
        case .decimal128(let decimal): return .text(decimal.description)
        case .javascript(let code): return .text("Code(\(ExtendedJSON.quoted(code)))")
        case let .javascriptWithScope(code, scope): return .text("Code(\(ExtendedJSON.quoted(code)), \(ExtendedJSON.string(scope)))")
        case .undefined, .regex, .dbPointer, .timestamp, .minKey, .maxKey: return .text(ExtendedJSON.string(value))
        }
    }

    /// Compact relaxed Extended JSON in stored order, cut at 10k characters.
    static func nested(_ value: BSONValue) -> String {
        let text = ExtendedJSON.string(value, mode: .relaxed)
        guard text.count > maxNestedLength else { return text }
        return String(text.prefix(maxNestedLength)) + "…"
    }

    private static let explicitLiteral = try? NSRegularExpression(
        pattern: #"^\s*(?:new\s+)?(?:ObjectId|ObjectID|ISODate|NumberLong|NumberInt|NumberDecimal|Decimal128|Int32|Long|Double|UUID|BinData|HexData|MD5|Timestamp|Code|DBRef|BSONRegExp|MinKey|MaxKey|Date)\s*\(|^\s*\{\s*["']?\$(?:oid|date|numberLong|numberInt|numberDouble|numberDecimal|binary|uuid|timestamp|regularExpression|code|minKey|maxKey|symbol|undefined)["']?\s*:"#
    )

    /// Parses text typed in a cell. `original` is the stored value (its type wins); `typeName` is the column's
    /// sampled type, used when the field was missing or null. Returns nil for `.missing`, which means `$unset`.
    static func value(fromCell cell: CellValue, original: BSONValue?, typeName: String?, field: String) throws -> BSONValue? {
        switch cell {
        case .missing: return nil
        case .null: return .null
        case .expression:
            throw DatabaseError.unsupported("SQL expressions such as DEFAULT cannot be saved to MongoDB documents.")
        case .bytes(let data):
            if case .binary(let subtype, _)? = original { return .binary(subtype: subtype, data: data) }
            return .binary(subtype: 0, data: data)
        case .text(let text):
            if let regex = explicitLiteral, regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
               let value = try? ExtendedJSON.parseValue(text)
            {
                return value
            }
            let stored = original.flatMap { $0 == .null ? nil : $0 }
            if stored == nil, typeName == "JSON", !["{", "["].contains(where: { text.trimmingCharacters(in: .whitespaces).hasPrefix($0) }) {
                // A mixed-type column voted JSON; plain text typed into an empty cell is a string.
                return .string(text)
            }
            return try parse(text, as: stored ?? typeName.flatMap(templateValue), field: field)
        }
    }

    /// A stand-in value of the column's type, so text typed into a missing or null cell is parsed the same way.
    static func templateValue(_ typeName: String) -> BSONValue? {
        switch typeName {
        case "FLOAT": return .double(0)
        case "INTEGER": return .int32(0)
        case "BIGINT": return .int64(0)
        case "decimal": return BSONDecimal128("0").map { .decimal128($0) }
        case "VARCHAR": return .string("")
        case "BOOLEAN": return .bool(false)
        case "TIMESTAMP": return .date(0)
        case "ObjectId": return .objectId(BSONObjectId.generate())
        case "UUID": return .binary(subtype: 4, data: Data(count: 16))
        case "BLOB": return .binary(subtype: 0, data: Data())
        case "JSON": return .document([:])
        default: return nil
        }
    }

    private static func invalid(_ text: String, _ type: String, _ field: String) -> DatabaseError {
        .server(message: "\"\(text)\" is not a valid \(type) value for field \"\(field)\".", code: nil)
    }

    static func parse(_ text: String, as template: BSONValue?, field: String) throws -> BSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let template else {
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let value = try? ExtendedJSON.parseValue(trimmed) { return value }
            return .string(text)
        }
        switch template {
        case .int32:
            if let value = Int32(trimmed) { return .int32(value) }
            if let value = Int64(trimmed) { return .int64(value) }
            if let value = Double(trimmed) { return .double(value) }
            throw invalid(text, "INTEGER", field)
        case .int64:
            if let value = Int64(trimmed) { return .int64(value) }
            if let value = Double(trimmed), trimmed.contains(where: { ".eE".contains($0) }) { return .double(value) }
            throw invalid(text, "BIGINT", field)
        case .double:
            if let value = Double(trimmed) { return .double(value) }
            switch trimmed.lowercased() {
            case "nan": return .double(.nan)
            case "infinity", "inf", "+infinity": return .double(.infinity)
            case "-infinity", "-inf": return .double(-.infinity)
            default: throw invalid(text, "FLOAT", field)
            }
        case .decimal128:
            guard let value = BSONDecimal128(trimmed) else { throw invalid(text, "decimal", field) }
            return .decimal128(value)
        case .string, .symbol:
            return .string(text)
        case .bool:
            switch trimmed.lowercased() {
            case "true", "1", "yes", "t", "y": return .bool(true)
            case "false", "0", "no", "f", "n": return .bool(false)
            default: throw invalid(text, "BOOLEAN", field)
            }
        case .date:
            if let milliseconds = ExtendedJSON.parseISODate(trimmed) { return .date(milliseconds) }
            if let milliseconds = Int64(trimmed) { return .date(milliseconds) }
            throw invalid(text, "date", field)
        case .objectId:
            guard let id = BSONObjectId(hex: trimmed) else { throw invalid(text, "ObjectId", field) }
            return .objectId(id)
        case .document, .array:
            do {
                return try ExtendedJSON.parseValue(trimmed, template: template)
            } catch {
                throw DatabaseError.server(message: "Field \"\(field)\": \(error.localizedDescription)", code: nil)
            }
        case .binary(let subtype, _):
            if subtype == 4, let data = MongoLiteral.uuidData(trimmed) { return .binary(subtype: 4, data: data) }
            let hex = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
            if let data = Data(hexString: hex) { return .binary(subtype: subtype, data: data) }
            throw invalid(text, "binary (hex)", field)
        case .regex(_, let options):
            if trimmed.hasPrefix("/"), let value = try? ExtendedJSON.parseValue(trimmed) { return value }
            return .regex(pattern: text, options: options)
        case .javascript:
            return .javascript(text)
        case .javascriptWithScope(_, let scope):
            return .javascriptWithScope(code: text, scope: scope)
        case .null:
            return .string(text)
        case .undefined, .dbPointer, .timestamp, .minKey, .maxKey:
            do {
                return try ExtendedJSON.parseValue(trimmed)
            } catch {
                throw DatabaseError.server(message: "Field \"\(field)\": \(error.localizedDescription)", code: nil)
            }
        }
    }

    /// Dotted-path `$set` / `$unset` entries that turn `old` into `new`, so untouched nested fields keep their types.
    static func diff(path: String, old: BSONValue, new: BSONValue, set: inout BSONDocument, unset: inout BSONDocument) {
        var pathSet = BSONDocument()
        var pathUnset = BSONDocument()
        let precise = diffInto(path: path, old: old, new: new, set: &pathSet, unset: &pathUnset, depth: 0)
        if !precise || pathSet.count + pathUnset.count > 64 {
            set[path] = new
            return
        }
        for element in pathSet.elements { set[element.key] = element.value }
        for element in pathUnset.elements { unset[element.key] = element.value }
    }

    private static func safeKey(_ key: String) -> Bool {
        !key.isEmpty && !key.contains(".") && !key.hasPrefix("$")
    }

    /// False when a dotted path cannot express the change and the whole field has to be set.
    private static func diffInto(path: String, old: BSONValue, new: BSONValue, set: inout BSONDocument, unset: inout BSONDocument, depth: Int) -> Bool {
        if old == new { return true }
        guard depth < 8 else { set[path] = new; return true }
        switch (old, new) {
        case let (.document(before), .document(after)):
            guard !after.isEmpty, after.keys.allSatisfy(safeKey), before.keys.allSatisfy(safeKey) else {
                set[path] = new
                return true
            }
            // A pure reorder cannot be expressed with dotted paths.
            if Set(before.keys) == Set(after.keys), before.keys != after.keys, before.elements.allSatisfy({ after[$0.key] == $0.value }) {
                set[path] = new
                return true
            }
            for element in after.elements {
                let childPath = path + "." + element.key
                if let previous = before[element.key] {
                    _ = diffInto(path: childPath, old: previous, new: element.value, set: &set, unset: &unset, depth: depth + 1)
                } else {
                    set[childPath] = element.value
                }
            }
            for key in before.keys where !after.contains(key) {
                unset[path + "." + key] = .string("")
            }
            return true
        case let (.array(before), .array(after)) where before.count == after.count:
            for index in after.indices {
                _ = diffInto(path: path + "." + String(index), old: before[index], new: after[index], set: &set, unset: &unset, depth: depth + 1)
            }
            return true
        default:
            set[path] = new
            return true
        }
    }
}

// MARK: - Filters

/// Builds a `find` filter from the filter bar rules.
enum MongoFilterBuilder {
    static func filter(rules: [FilterRule], fieldTypes: [String: String], raw: BSONDocument?) -> BSONDocument {
        var conditions: [BSONDocument] = rules.compactMap { condition(for: $0, typeName: fieldTypes[$0.column]) }
        if let raw, !raw.isEmpty { conditions.append(raw) }
        switch conditions.count {
        case 0: return [:]
        case 1: return conditions[0]
        default: return ["$and": .array(conditions.map { .document($0) })]
        }
    }

    static func condition(for rule: FilterRule, typeName: String?) -> BSONDocument? {
        guard rule.isEnabled, !rule.column.isEmpty else { return nil }
        let field = rule.column
        let candidates = typedValues(rule.value, typeName: typeName)
        let primary = candidates.first { $0.stringValue == nil } ?? candidates.first ?? .string(rule.value)
        func operation(_ name: String, _ value: BSONValue) -> BSONDocument { [field: .document([name: value])] }
        switch rule.op {
        case .equals:
            if typeName == "TIMESTAMP", let day = dayRange(rule.value) {
                return [field: .document(["$gte": .date(day.lowerBound), "$lt": .date(day.upperBound)])]
            }
            return candidates.count == 1 ? operation("$eq", candidates[0]) : operation("$in", .array(candidates))
        case .notEquals:
            return candidates.count == 1 ? operation("$ne", candidates[0]) : operation("$nin", .array(candidates))
        case .greaterThan: return operation("$gt", primary)
        case .greaterOrEqual: return operation("$gte", primary)
        case .lessThan: return operation("$lt", primary)
        case .lessOrEqual: return operation("$lte", primary)
        case .contains: return [field: regex(escape(rule.value))]
        case .notContains: return operation("$not", regex(escape(rule.value)))
        case .startsWith: return [field: regex("^" + escape(rule.value))]
        case .endsWith: return [field: regex(escape(rule.value) + "$")]
        case .isNull: return [field: .null]
        case .isNotNull: return operation("$ne", .null)
        case .inList:
            let items = rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return operation("$in", .array(items.flatMap { typedValues($0, typeName: typeName) }))
        }
    }

    private static func regex(_ pattern: String) -> BSONValue { .regex(pattern: pattern, options: "i") }

    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\^$.|?*+()[]{}/".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// `2024-05-01` matches the whole UTC day.
    private static func dayRange(_ text: String) -> Range<Int64>? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, let start = ExtendedJSON.parseISODate(trimmed) else { return nil }
        return start..<(start + 86_400_000)
    }

    private static func number(_ text: String) -> BSONValue? {
        if let value = Int32(text) { return .int32(value) }
        if let value = Int64(text) { return .int64(value) }
        if let value = Double(text), text.rangeOfCharacter(from: .decimalDigits) != nil { return .double(value) }
        return nil
    }

    /// The values a typed filter text may mean. Equality matches any of them.
    static func typedValues(_ raw: String, typeName: String?) -> [BSONValue] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^(?:new\s+)?(?:ObjectId|ISODate|NumberLong|NumberInt|NumberDecimal|Decimal128|UUID|Timestamp|BinData)\s*\("#, options: .regularExpression) != nil,
           let value = try? ExtendedJSON.parseValue(text)
        {
            return [value]
        }
        let string = BSONValue.string(raw)
        switch typeName {
        case "INTEGER"?, "BIGINT"?, "FLOAT"?:
            return number(text).map { [$0] } ?? [string]
        case "decimal"?:
            return BSONDecimal128(text).map { [.decimal128($0)] } ?? [string]
        case "BOOLEAN"?:
            switch text.lowercased() {
            case "true": return [.bool(true)]
            case "false": return [.bool(false)]
            default: return [string]
            }
        case "TIMESTAMP"?:
            return ExtendedJSON.parseISODate(text).map { [.date($0)] } ?? [string]
        case "ObjectId"?:
            return BSONObjectId(hex: text).map { [.objectId($0), .string(text)] } ?? [string]
        case "UUID"?:
            return MongoLiteral.uuidData(text).map { [.binary(subtype: 4, data: $0)] } ?? [string]
        case "VARCHAR"?:
            return [string]
        case "JSON"?:
            if let value = try? ExtendedJSON.parseValue(text) { return [value] }
            return [string]
        default:
            if let id = BSONObjectId(hex: text) { return [.objectId(id), .string(text)] }
            if let value = number(text) { return [value, string] }
            if text == "true" || text == "false" { return [.bool(text == "true"), string] }
            return [string]
        }
    }
}

// MARK: - Grid

enum MongoGrid {
    struct Column {
        var name: String
        var typeName: String
    }

    /// `_id` first, the rest alphabetical: the union of `base` (sampled) fields and the fields of these documents.
    static func columns(for documents: [BSONDocument], base: [Column] = []) -> [Column] {
        var types: [String: String] = [:]
        for column in base { types[column.name] = column.typeName }
        var names = Set(base.map(\.name))
        for document in documents {
            for key in document.keys { names.insert(key) }
        }
        let ordered = (names.contains("_id") ? ["_id"] : []) + names.filter { $0 != "_id" }.sorted()
        return ordered.map { name in
            if let known = types[name] { return Column(name: name, typeName: known) }
            let vote = MongoCellCodec.voteTypeName(documents.lazy.compactMap { $0[name] })
            return Column(name: name, typeName: vote ?? "VARCHAR")
        }
    }

    static func result(_ documents: [BSONDocument], base: [Column] = [], table: String? = nil) -> StatementResult {
        var columns = columns(for: documents, base: base)
        if columns.isEmpty { columns = [Column(name: "_id", typeName: "ObjectId")] }
        let rows = documents.map { document -> [CellValue] in
            var fields: [String: BSONValue] = [:]
            for element in document.elements where fields[element.key] == nil { fields[element.key] = element.value }
            return columns.map { MongoCellCodec.cell(fields[$0.name]) }
        }
        return StatementResult(
            columns: columns.map { ResultColumn(name: $0.name, typeName: $0.typeName, isNumeric: MongoCellCodec.numericTypes.contains($0.typeName), tableName: table) },
            rows: rows
        )
    }
}

// MARK: - Browsing and saving

extension MongoConnection {
    func cacheKey(_ collection: String) -> String { "\(databaseName).\(collection)" }

    /// A filter document typed in the filter bar: Extended JSON or shell syntax, falling back to the script runtime
    /// for expressions such as `{ createdAt: { $gt: new Date(Date.now() - 86400000) } }`.
    func parseRawFilter(_ text: String) throws -> BSONDocument? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let literalError: Error
        do {
            return try ExtendedJSON.parseDocument(trimmed)
        } catch {
            literalError = error
        }
        guard let outcome = try? scriptRuntime().evaluateExpression(trimmed) else {
            throw DatabaseError.server(message: "Invalid filter: \(literalError.localizedDescription)", code: nil)
        }
        guard case .document(let document) = outcome else {
            throw DatabaseError.server(message: "The filter must be a document such as { status: \"paid\" }", code: nil)
        }
        return document
    }

    func filter(for query: TableQuery, schema: MongoSampledSchema) throws -> BSONDocument {
        let types = Dictionary(schema.fields.map { ($0.name, $0.typeName) }, uniquingKeysWith: { first, _ in first })
        return MongoFilterBuilder.filter(rules: query.filters, fieldTypes: types, raw: try parseRawFilter(query.rawWhere))
    }

    public func fetchRows(_ query: TableQuery) throws -> StatementResult {
        try beginOperation()
        return try mapped {
            let started = Date()
            let collection = query.table.name
            let schema = try sampledSchema(collection)
            var command: BSONDocument = ["find": .string(collection), "filter": .document(try filter(for: query, schema: schema))]
            if !query.sort.isEmpty {
                command["sort"] = .document(BSONDocument(query.sort.map { ($0.column, .int32($0.ascending ? 1 : -1)) }))
            }
            let pageSize = max(1, query.pageSize)
            if query.page > 0 { command["skip"] = .int64(Int64(query.page) * Int64(pageSize)) }
            command["limit"] = .int64(Int64(pageSize))
            let (documents, _) = try cursorDocuments(command, database: databaseName, limit: pageSize)
            var page: [String: BSONDocument] = [:]
            for document in documents {
                page[ExtendedJSON.string(document["_id"] ?? .null, mode: .canonical)] = document
            }
            pageCache[cacheKey(collection)] = page
            var result = MongoGrid.result(documents, base: schema.fields.map { MongoGrid.Column(name: $0.name, typeName: $0.typeName) }, table: collection)
            result.elapsed = Date().timeIntervalSince(started)
            return result
        }
    }

    public func countRows(_ query: TableQuery) throws -> Int? {
        try beginOperation()
        return try mapped {
            let collection = query.table.name
            let schema = try sampledSchema(collection)
            let filter = try filter(for: query, schema: schema)
            if filter.isEmpty {
                let reply = try runCommand(["count": .string(collection)], database: databaseName)
                return reply["n"]?.intValue
            }
            do {
                let reply = try runCommand([
                    "aggregate": .string(collection),
                    "pipeline": .array([.document(["$match": .document(filter)]), .document(["$count": .string("n")])]),
                    "cursor": .document([:]),
                    "maxTimeMS": .int32(10_000),
                ], database: databaseName)
                let batch = reply["cursor"]?.documentValue?["firstBatch"]?.arrayValue ?? []
                return batch.first?.documentValue?["n"]?.intValue ?? 0
            } catch let error as MongoServerError where error.code == MongoServerError.maxTimeMSExpired {
                return nil
            }
        }
    }

    /// The stored document behind a grid row: from the last page when possible, else looked up by `_id`.
    private func storedDocument(row: Int, batch: ChangeBatch, idIndex: Int) throws -> BSONDocument {
        guard batch.originalRows.indices.contains(row), batch.originalRows[row].indices.contains(idIndex) else {
            throw StatementGenerationError.missingOriginalRow(row)
        }
        let original = batch.originalRows[row]
        let idCell = original[idIndex]
        let page = pageCache[cacheKey(batch.table.name)] ?? [:]
        let matches = page.values.filter { MongoCellCodec.cell($0["_id"]) == idCell }
        if matches.count == 1, let match = matches.first { return match }
        if matches.count > 1 {
            // Two _id values that display alike (an ObjectId and its hex string): compare every cell.
            let names = batch.columns.map(\.name)
            if let exact = matches.first(where: { document in names.indices.allSatisfy { original.indices.contains($0) && MongoCellCodec.cell(document[names[$0]]) == original[$0] } }) {
                return exact
            }
        }
        let typeName = batch.columns[idIndex].typeName
        let candidates: [BSONValue]
        if case .text(let text) = idCell {
            candidates = (try? MongoCellCodec.value(fromCell: idCell, original: nil, typeName: nil, field: "_id")).flatMap { value -> [BSONValue]? in
                value.stringValue == nil ? [value] : nil
            } ?? MongoFilterBuilder.typedValues(text, typeName: typeName == "VARCHAR" ? nil : typeName)
        } else if case .bytes(let data) = idCell {
            candidates = [.binary(subtype: 0, data: data)]
        } else {
            candidates = [.null]
        }
        let (found, _) = try cursorDocuments(
            ["find": .string(batch.table.name), "filter": .document(["_id": .document(["$in": .array(candidates)])]), "limit": .int32(2)],
            database: databaseName, limit: 2
        )
        guard found.count == 1, let document = found.first else {
            throw DatabaseError.server(message: "The document with _id \(idCell.displayString) could not be found; reload the page and try again.", code: nil)
        }
        return document
    }

    /// Saves grid edits one write at a time: MongoDB standalone servers have no multi-document transactions,
    /// so on failure the error says which part failed and how many earlier writes were kept.
    public func applyChanges(_ batch: ChangeBatch) throws {
        try beginOperation()
        let collection = batch.table.name
        let changes = batch.changes
        let idIndex = batch.columns.firstIndex { $0.name == "_id" }
        var saved = 0

        func failure(_ part: String, _ error: Error) -> Error {
            let message = (mapError(error) as? LocalizedError)?.errorDescription ?? "\(error)"
            var text = "Saving stopped at \(part): \(message)"
            if saved > 0 { text += " \(saved) earlier change\(saved == 1 ? " was" : "s were") saved and cannot be rolled back." }
            if case DatabaseError.cancelled = error { return error }
            return DatabaseError.server(message: text, code: nil)
        }

        let deletedRows = changes.deletions.sorted()
        if !deletedRows.isEmpty {
            guard let idIndex else { throw DatabaseError.server(message: "Deleting documents needs the _id column.", code: nil) }
            do {
                let ids = try deletedRows.map { row -> BSONValue in
                    try storedDocument(row: row, batch: batch, idIndex: idIndex)["_id"] ?? .null
                }
                let filter: BSONDocument = ids.count == 1 ? ["_id": ids[0]] : ["_id": .document(["$in": .array(ids)])]
                try runCommand([
                    "delete": .string(collection),
                    "deletes": .array([.document(["q": .document(filter), "limit": .int32(ids.count == 1 ? 1 : 0)])]),
                ], database: databaseName)
                saved += ids.count
            } catch {
                throw failure("deleting \(deletedRows.count) document\(deletedRows.count == 1 ? "" : "s")", error)
            }
        }

        for row in changes.updates.keys.sorted() where !changes.deletions.contains(row) {
            guard let rowChanges = changes.updates[row], !rowChanges.isEmpty else { continue }
            do {
                guard let idIndex else { throw DatabaseError.server(message: "Editing documents needs the _id column.", code: nil) }
                let stored = try storedDocument(row: row, batch: batch, idIndex: idIndex)
                var set = BSONDocument()
                var unset = BSONDocument()
                for column in rowChanges.keys.sorted() {
                    guard batch.columns.indices.contains(column), let cell = rowChanges[column] else { continue }
                    let name = batch.columns[column].name
                    guard name != "_id" else { throw DatabaseError.server(message: "_id cannot be changed.", code: nil) }
                    let old = stored[name]
                    guard let new = try MongoCellCodec.value(fromCell: cell, original: old, typeName: batch.columns[column].typeName, field: name) else {
                        if old != nil { unset[name] = .string("") }
                        continue
                    }
                    if let old, old != .null {
                        MongoCellCodec.diff(path: name, old: old, new: new, set: &set, unset: &unset)
                    } else {
                        set[name] = new
                    }
                }
                guard !set.isEmpty || !unset.isEmpty else { continue }
                var update = BSONDocument()
                if !set.isEmpty { update["$set"] = .document(set) }
                if !unset.isEmpty { update["$unset"] = .document(unset) }
                let reply = try runCommand([
                    "update": .string(collection),
                    "updates": .array([.document(["q": .document(["_id": stored["_id"] ?? .null]), "u": .document(update), "multi": .bool(false)])]),
                ], database: databaseName)
                guard (reply["n"]?.intValue ?? 0) > 0 else {
                    throw DatabaseError.server(message: "The document no longer exists.", code: nil)
                }
                saved += 1
            } catch {
                throw failure("row \(row + 1)", error)
            }
        }

        for (index, values) in changes.insertions.enumerated() {
            do {
                var document = BSONDocument()
                for (column, value) in values.enumerated() where batch.columns.indices.contains(column) {
                    guard case .value(let cell) = value else { continue }
                    if cell == .missing { continue }
                    if case .text(let text) = cell, text.isEmpty { continue }
                    let info = batch.columns[column]
                    guard let parsed = try MongoCellCodec.value(fromCell: cell, original: nil, typeName: info.typeName, field: info.name) else { continue }
                    document[info.name] = parsed
                }
                document.prepend("_id", document["_id"] ?? .objectId(.generate()))
                try runCommand(["insert": .string(collection), "documents": .array([.document(document)])], database: databaseName)
                saved += 1
            } catch {
                throw failure("new document \(index + 1)", error)
            }
        }
    }

    // MARK: Shell results

    /// Turns a shell outcome into a result grid. Documents use the browse column rules.
    func renderOutcome(_ outcome: MongoScriptOutcome, rowLimit: Int?, output: [String]) throws -> StatementResult {
        let printed = output.isEmpty ? nil : output.joined(separator: "\n")
        var result: StatementResult
        switch outcome {
        case let .cursor(database, command):
            let (documents, more) = try cursorDocuments(command, database: database, limit: rowLimit)
            result = MongoGrid.result(documents)
            result.truncated = more
        case let .documents(documents, truncated):
            let capped = rowLimit.map { Array(documents.prefix($0)) } ?? documents
            result = MongoGrid.result(capped)
            result.truncated = truncated || capped.count < documents.count
        case .document(let document):
            result = MongoGrid.result([document])
            result.affectedRows = Self.affectedRows(document)
        case let .values(values, truncated):
            let capped = rowLimit.map { Array(values.prefix($0)) } ?? values
            let typeName = MongoCellCodec.voteTypeName(capped) ?? "VARCHAR"
            result = StatementResult(
                columns: [ResultColumn(name: "result", typeName: typeName, isNumeric: MongoCellCodec.numericTypes.contains(typeName))],
                rows: capped.map { [MongoCellCodec.cell($0)] },
                truncated: truncated || capped.count < values.count
            )
        case .value(let value):
            let typeName = MongoCellCodec.typeName(value) ?? "VARCHAR"
            result = StatementResult(
                columns: [ResultColumn(name: "result", typeName: typeName, isNumeric: MongoCellCodec.numericTypes.contains(typeName))],
                rows: [[MongoCellCodec.cell(value)]]
            )
        case .message(let text):
            return StatementResult(message: printed.map { $0 + "\n" + text } ?? text)
        case .none:
            guard !output.isEmpty else { return StatementResult() }
            return StatementResult(columns: [ResultColumn(name: "output", typeName: "VARCHAR")], rows: output.map { [.text($0)] })
        }
        if let printed { result.message = printed }
        return result
    }

    /// Write results report `insertedCount`, `modifiedCount`, `deletedCount` or `n`.
    static func affectedRows(_ document: BSONDocument) -> Int? {
        if let count = document["insertedCount"]?.intValue { return count }
        if let modified = document["modifiedCount"]?.intValue { return modified + (document["upsertedCount"]?.intValue ?? 0) }
        if let count = document["deletedCount"]?.intValue { return count }
        if let count = document["n"]?.intValue { return count }
        if let id = document["insertedId"], id != .null, document["acknowledged"] != nil { return 1 }
        return nil
    }
}
