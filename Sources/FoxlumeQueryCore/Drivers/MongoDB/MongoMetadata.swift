import Foundation

/// Top-level fields of a collection, inferred from a sample of documents plus its `$jsonSchema` validator.
struct MongoSampledSchema {
    struct Field {
        var name: String
        var typeName: String
        /// Sampled documents that have the field, and how many of those hold a non-null value.
        var present: Int
        var nonNull: Int
        var required: Bool
    }

    static let sampleSize = 200

    var fields: [Field]
    var sampled: Int

    func field(_ name: String) -> Field? { fields.first { $0.name == name } }

    /// `$jsonSchema` `bsonType` names mapped to the grid's column types.
    static func typeName(forSchemaType type: String) -> String? {
        switch type {
        case "double": return "FLOAT"
        case "int": return "INTEGER"
        case "long": return "BIGINT"
        case "decimal": return "decimal"
        case "number": return "FLOAT"
        case "string": return "VARCHAR"
        case "bool": return "BOOLEAN"
        case "date": return "TIMESTAMP"
        case "objectId": return "ObjectId"
        case "object", "array": return "JSON"
        case "binData": return "BLOB"
        default: return nil
        }
    }

    init(documents: [BSONDocument], validator: BSONDocument?) {
        sampled = documents.count
        var values: [String: [BSONValue]] = [:]
        var presence: [String: Int] = [:]
        for document in documents {
            var seen = Set<String>()
            for element in document.elements where seen.insert(element.key).inserted {
                values[element.key, default: []].append(element.value)
                presence[element.key, default: 0] += 1
            }
        }
        var schemaTypes: [String: String] = [:]
        var required = Set<String>()
        if let schema = validator?["$jsonSchema"]?.documentValue {
            for property in schema["properties"]?.documentValue?.elements ?? [] {
                let spec = property.value.documentValue
                let declared: String? = spec?["bsonType"]?.stringValue
                    ?? spec?["bsonType"]?.arrayValue?.compactMap(\.stringValue).first { $0 != "null" }
                    ?? spec?["type"]?.stringValue
                schemaTypes[property.key] = declared.flatMap(Self.typeName(forSchemaType:)) ?? "VARCHAR"
            }
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                required.insert(name)
                if schemaTypes[name] == nil { schemaTypes[name] = "VARCHAR" }
            }
        }
        let names = Set(values.keys).union(schemaTypes.keys)
        let ordered = (names.contains("_id") ? ["_id"] : []) + names.filter { $0 != "_id" }.sorted()
        fields = ordered.map { name in
            let sampledValues = values[name] ?? []
            let voted = MongoCellCodec.voteTypeName(sampledValues)
            return Field(
                name: name,
                typeName: voted ?? schemaTypes[name] ?? "VARCHAR",
                present: presence[name] ?? 0,
                nonNull: sampledValues.filter { $0 != .null }.count,
                required: required.contains(name)
            )
        }
    }
}

extension MongoConnection {
    /// Collection info from `listCollections`, or nil when it does not exist.
    func collectionInfo(_ name: String) throws -> BSONDocument? {
        let (items, _) = try cursorDocuments(
            ["listCollections": .int32(1), "filter": .document(["name": .string(name)]), "cursor": .document([:])],
            database: databaseName, limit: nil
        )
        return items.first
    }

    func sampledSchema(_ collection: String, refresh: Bool = false) throws -> MongoSampledSchema {
        let key = cacheKey(collection)
        if !refresh, let cached = schemaCache[key] { return cached }
        let (documents, _) = try cursorDocuments(
            ["find": .string(collection), "filter": .document([:]), "limit": .int32(Int32(MongoSampledSchema.sampleSize))],
            database: databaseName, limit: MongoSampledSchema.sampleSize
        )
        let info = try? collectionInfo(collection)
        let schema = MongoSampledSchema(documents: documents, validator: info?["options"]?.documentValue?["validator"]?.documentValue)
        schemaCache[key] = schema
        return schema
    }

    public func databases() throws -> [String] {
        try beginOperation()
        return try mapped {
            do {
                let reply = try runCommand(["listDatabases": .int32(1), "nameOnly": .bool(true), "authorizedDatabases": .bool(true)], database: "admin")
                var names = (reply["databases"]?.arrayValue ?? []).compactMap { $0.documentValue?["name"]?.stringValue }
                if !databaseName.isEmpty, !names.contains(databaseName) { names.append(databaseName) }
                return names.sorted()
            } catch let error as MongoServerError where error.code == MongoServerError.unauthorized {
                return databaseName.isEmpty ? [] : [databaseName]
            }
        }
    }

    public func tables(schema: String?) throws -> [TableInfo] {
        try beginOperation()
        return try mapped {
            let (items, _) = try cursorDocuments(
                ["listCollections": .int32(1), "authorizedCollections": .bool(true), "nameOnly": .bool(false), "cursor": .document([:])],
                database: databaseName, limit: nil
            )
            var tables: [TableInfo] = items.compactMap { item in
                guard let name = item["name"]?.stringValue else { return nil }
                let kind: TableKind
                if item["type"]?.stringValue == "view" {
                    kind = .view
                } else if name.hasPrefix("system.") {
                    kind = .systemTable
                } else {
                    kind = .table
                }
                let comment = item["type"]?.stringValue == "timeseries" ? "time series" : nil
                return TableInfo(ref: TableRef(name: name), kind: kind, comment: comment)
            }
            tables.sort { $0.name < $1.name }
            var counted = 0
            for index in tables.indices where tables[index].kind != .view && counted < 100 {
                counted += 1
                let reply = try? runCommand(["count": .string(tables[index].name)], database: databaseName)
                tables[index].estimatedRows = reply?["n"]?.intValue
            }
            return tables
        }
    }

    public func structure(of table: TableRef) throws -> TableStructure {
        try beginOperation()
        return try mapped {
            let schema = try sampledSchema(table.name, refresh: true)
            let columns = schema.fields.map { field -> ColumnInfo in
                let alwaysSet = schema.sampled > 0 && field.present == schema.sampled && field.nonNull == field.present
                return ColumnInfo(
                    name: field.name,
                    dataType: field.typeName,
                    isNullable: field.name != "_id" && !field.required && !alwaysSet,
                    isPrimaryKey: field.name == "_id",
                    extra: schema.sampled > 0 ? "in \(field.present) of \(schema.sampled) sampled documents" : nil
                )
            }
            let info = try collectionInfo(table.name)
            guard info?["type"]?.stringValue != "view" else {
                return TableStructure(table: table, columns: columns)
            }
            return TableStructure(table: table, columns: columns, indexes: try indexes(of: table.name).map(Self.indexInfo))
        }
    }

    func indexes(of collection: String) throws -> [BSONDocument] {
        do {
            return try cursorDocuments(["listIndexes": .string(collection), "cursor": .document([:])], database: databaseName, limit: nil).documents
        } catch let error as MongoServerError where error.code == MongoServerError.namespaceNotFound {
            return []
        }
    }

    static func indexInfo(_ index: BSONDocument) -> IndexInfo {
        let name = index["name"]?.stringValue ?? ""
        let key = index["key"]?.documentValue ?? [:]
        let special = key.values.compactMap(\.stringValue).first
        var columns = key.keys
        if special == "text" {
            // Text indexes store `_fts` / `_ftsx`; the indexed fields are the weights.
            let fields = index["weights"]?.documentValue?.keys ?? []
            columns = key.keys.filter { $0 != "_fts" && $0 != "_ftsx" } + fields
        }
        return IndexInfo(
            name: name,
            columns: columns,
            isUnique: name == "_id_" || index["unique"]?.boolValue == true,
            isPrimary: name == "_id_",
            method: special
        )
    }

    /// The key and options to pass to `createIndex` for a `listIndexes` entry. Text indexes are written the way
    /// people create them (`{ name: "text" }`) and server-filled version fields are left out.
    static func createIndexArguments(_ index: BSONDocument) -> (key: BSONDocument, options: BSONDocument) {
        var key = index["key"]?.documentValue ?? [:]
        var options = index
        for field in ["v", "key", "ns", "textIndexVersion", "2dsphereIndexVersion"] { options.removeValue(forKey: field) }
        if key["_fts"] == .string("text"), let weights = index["weights"]?.documentValue {
            var rebuilt = BSONDocument()
            for element in key.elements {
                if element.key == "_fts" {
                    for field in weights.keys { rebuilt[field] = .string("text") }
                } else if element.key != "_ftsx" {
                    rebuilt[element.key] = element.value
                }
            }
            key = rebuilt
            if weights.values.allSatisfy({ $0.int64Value == 1 }) { options.removeValue(forKey: "weights") }
            if options["language_override"] == .string("language") { options.removeValue(forKey: "language_override") }
        }
        return (key, options)
    }

    /// MQL that recreates the collection or view with its options and indexes.
    public func ddl(of table: TableRef) throws -> String {
        try beginOperation()
        return try mapped {
            guard let info = try collectionInfo(table.name) else {
                throw DatabaseError.server(message: "Collection \"\(table.name)\" does not exist in \(databaseName).", code: "NamespaceNotFound")
            }
            let name = ExtendedJSON.quoted(table.name)
            var options = info["options"]?.documentValue ?? [:]
            if info["type"]?.stringValue == "view" {
                let source = options.removeValue(forKey: "viewOn")?.stringValue ?? ""
                let pipeline = options.removeValue(forKey: "pipeline") ?? .array([])
                var text = "db.createView(\(name), \(ExtendedJSON.quoted(source)), \(MongoShellFormatter.format(pipeline, pretty: true))"
                if !options.isEmpty { text += ", \(MongoShellFormatter.format(.document(options), pretty: true))" }
                return text + ");"
            }
            var statements: [String] = []
            if options.isEmpty {
                statements.append("db.createCollection(\(name));")
            } else {
                statements.append("db.createCollection(\(name), \(MongoShellFormatter.format(.document(options), pretty: true)));")
            }
            for index in try indexes(of: table.name) where index["name"]?.stringValue != "_id_" {
                let (key, indexOptions) = Self.createIndexArguments(index)
                statements.append("db.getCollection(\(name)).createIndex(\(MongoShellFormatter.format(.document(key))), \(MongoShellFormatter.format(.document(indexOptions))));")
            }
            return statements.joined(separator: "\n")
        }
    }
}
