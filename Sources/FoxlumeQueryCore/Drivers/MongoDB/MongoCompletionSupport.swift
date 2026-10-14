import Foundation

extension MongoConnection {
    static let completionSampleSize = 50
    /// Paths deeper than this many segments are left out.
    static let completionMaxDepth = 5
    static let completionMaxPaths = 500

    /// Dotted field paths seen in up to 50 sampled documents of `collection`, with BSON type names (spec 8.4).
    public func completionFields(collection: String) throws -> [CompletionField] {
        try beginOperation()
        return try mapped {
            let (documents, _) = try cursorDocuments(
                ["find": .string(collection), "filter": .document([:]), "limit": .int32(Int32(Self.completionSampleSize))],
                database: databaseName, limit: Self.completionSampleSize
            )
            return Self.completionFields(in: documents)
        }
    }

    /// Every dotted path of `documents`: embedded documents are walked, and so are documents inside arrays (their
    /// paths continue the array's path, as queries address them). `_id` first, then in order of first appearance.
    /// The type is the most common non-null BSON type alias (`string`, `int`, `object`…), `null` when only nulls were seen.
    static func completionFields(in documents: [BSONDocument]) -> [CompletionField] {
        var order: [String] = []
        var votes: [String: [String: Int]] = [:]
        var firstTypes: [String: [String]] = [:]

        func record(_ path: String, _ value: BSONValue) -> Bool {
            if votes[path] == nil {
                guard order.count < completionMaxPaths else { return false }
                order.append(path)
                votes[path] = [:]
                firstTypes[path] = []
            }
            guard value != .null else { return true }
            let alias = value.typeAlias
            if votes[path]?[alias] == nil { firstTypes[path]?.append(alias) }
            votes[path]?[alias, default: 0] += 1
            return true
        }

        func visit(_ document: BSONDocument, prefix: String, depth: Int) {
            for element in document.elements where !element.key.isEmpty {
                let path = prefix.isEmpty ? element.key : prefix + "." + element.key
                guard record(path, element.value), depth < completionMaxDepth else { continue }
                descend(element.value, path: path, depth: depth + 1)
            }
        }

        func descend(_ value: BSONValue, path: String, depth: Int) {
            switch value {
            case .document(let document):
                visit(document, prefix: path, depth: depth)
            case .array(let items):
                for item in items { descend(item, path: path, depth: depth) }
            default:
                break
            }
        }

        for document in documents { visit(document, prefix: "", depth: 1) }

        if let id = order.firstIndex(of: "_id"), id > 0 { order.insert(order.remove(at: id), at: 0) }
        return order.map { path in
            let counts = votes[path] ?? [:]
            var best: String?
            for alias in firstTypes[path] ?? [] where best == nil || (counts[alias] ?? 0) > (counts[best ?? ""] ?? 0) {
                best = alias
            }
            return CompletionField(path: path, typeName: best ?? "null")
        }
    }
}
