import CDuckDB
import Foundation

/// A DuckDB logical type, read once per column so decoding a chunk makes no type calls per value.
/// Owns the C handle, which the value API needs to build LIST, STRUCT, MAP, UNION and ENUM values.
final class DuckDBType {
    struct Member {
        let name: String
        let type: DuckDBType
    }

    let handle: duckdb_logical_type
    let id: duckdb_type
    /// Set for aliased types such as `JSON` and user-defined types from `CREATE TYPE`.
    let alias: String?
    /// The element of LIST and ARRAY, key then value of MAP, members of STRUCT and UNION.
    let members: [Member]
    let arraySize: Int
    let decimalWidth: UInt8
    let decimalScale: UInt8
    /// Physical storage of DECIMAL and ENUM values.
    let storage: duckdb_type
    let enumValues: [String]

    init(taking handle: duckdb_logical_type) {
        self.handle = handle
        id = duckdb_get_type_id(handle)
        alias = Self.takeString(duckdb_logical_type_get_alias(handle))

        var members: [Member] = []
        var arraySize = 0
        var decimalWidth: UInt8 = 0
        var decimalScale: UInt8 = 0
        var storage = DUCKDB_TYPE_INVALID
        var enumValues: [String] = []
        switch id {
        case DUCKDB_TYPE_LIST:
            if let child = duckdb_list_type_child_type(handle) {
                members = [Member(name: "", type: DuckDBType(taking: child))]
            }
        case DUCKDB_TYPE_ARRAY:
            if let child = duckdb_array_type_child_type(handle) {
                members = [Member(name: "", type: DuckDBType(taking: child))]
            }
            arraySize = Int(duckdb_array_type_array_size(handle))
        case DUCKDB_TYPE_MAP:
            if let key = duckdb_map_type_key_type(handle), let value = duckdb_map_type_value_type(handle) {
                members = [Member(name: "key", type: DuckDBType(taking: key)), Member(name: "value", type: DuckDBType(taking: value))]
            }
        case DUCKDB_TYPE_STRUCT:
            for index in 0..<duckdb_struct_type_child_count(handle) {
                guard let child = duckdb_struct_type_child_type(handle, index) else { continue }
                let name = Self.takeString(duckdb_struct_type_child_name(handle, index)) ?? ""
                members.append(Member(name: name, type: DuckDBType(taking: child)))
            }
        case DUCKDB_TYPE_UNION:
            for index in 0..<duckdb_union_type_member_count(handle) {
                guard let child = duckdb_union_type_member_type(handle, index) else { continue }
                let name = Self.takeString(duckdb_union_type_member_name(handle, index)) ?? ""
                members.append(Member(name: name, type: DuckDBType(taking: child)))
            }
        case DUCKDB_TYPE_DECIMAL:
            decimalWidth = duckdb_decimal_width(handle)
            decimalScale = duckdb_decimal_scale(handle)
            storage = duckdb_decimal_internal_type(handle)
        case DUCKDB_TYPE_ENUM:
            storage = duckdb_enum_internal_type(handle)
            enumValues = (0..<UInt64(duckdb_enum_dictionary_size(handle))).map {
                Self.takeString(duckdb_enum_dictionary_value(handle, $0)) ?? ""
            }
        default:
            break
        }
        self.members = members
        self.arraySize = arraySize
        self.decimalWidth = decimalWidth
        self.decimalScale = decimalScale
        self.storage = storage
        self.enumValues = enumValues
    }

    deinit {
        var owned: duckdb_logical_type? = handle
        duckdb_destroy_logical_type(&owned)
    }

    /// Copies and frees a string that DuckDB allocated for the caller.
    static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { duckdb_free(pointer) }
        return String(cString: pointer)
    }

    /// The type as DuckDB spells it, for example `DECIMAL(12,4)`, `INTEGER[]` or `STRUCT(a INTEGER, b VARCHAR)`.
    /// `keywords` holds DuckDB's keywords, which it quotes when they name a STRUCT or UNION member.
    func name(keywords: Set<String>) -> String {
        if let alias, !alias.isEmpty { return alias }
        switch id {
        case DUCKDB_TYPE_DECIMAL: return "DECIMAL(\(decimalWidth),\(decimalScale))"
        case DUCKDB_TYPE_ENUM:
            return "ENUM(" + enumValues.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ") + ")"
        case DUCKDB_TYPE_LIST:
            return (members.first?.type.name(keywords: keywords) ?? "ANY") + "[]"
        case DUCKDB_TYPE_ARRAY:
            return (members.first?.type.name(keywords: keywords) ?? "ANY") + "[\(arraySize)]"
        case DUCKDB_TYPE_MAP:
            return "MAP(" + members.map { $0.type.name(keywords: keywords) }.joined(separator: ", ") + ")"
        case DUCKDB_TYPE_STRUCT, DUCKDB_TYPE_UNION:
            let fields = members.map { Self.memberName($0.name, keywords: keywords) + " " + $0.type.name(keywords: keywords) }
            return (id == DUCKDB_TYPE_STRUCT ? "STRUCT(" : "UNION(") + fields.joined(separator: ", ") + ")"
        default:
            return Self.scalarNames[id.rawValue] ?? "UNKNOWN"
        }
    }

    private static let scalarNames: [UInt32: String] = [
        DUCKDB_TYPE_BOOLEAN.rawValue: "BOOLEAN",
        DUCKDB_TYPE_TINYINT.rawValue: "TINYINT",
        DUCKDB_TYPE_SMALLINT.rawValue: "SMALLINT",
        DUCKDB_TYPE_INTEGER.rawValue: "INTEGER",
        DUCKDB_TYPE_BIGINT.rawValue: "BIGINT",
        DUCKDB_TYPE_UTINYINT.rawValue: "UTINYINT",
        DUCKDB_TYPE_USMALLINT.rawValue: "USMALLINT",
        DUCKDB_TYPE_UINTEGER.rawValue: "UINTEGER",
        DUCKDB_TYPE_UBIGINT.rawValue: "UBIGINT",
        DUCKDB_TYPE_HUGEINT.rawValue: "HUGEINT",
        DUCKDB_TYPE_UHUGEINT.rawValue: "UHUGEINT",
        DUCKDB_TYPE_FLOAT.rawValue: "FLOAT",
        DUCKDB_TYPE_DOUBLE.rawValue: "DOUBLE",
        DUCKDB_TYPE_VARCHAR.rawValue: "VARCHAR",
        DUCKDB_TYPE_BLOB.rawValue: "BLOB",
        DUCKDB_TYPE_DATE.rawValue: "DATE",
        DUCKDB_TYPE_TIME.rawValue: "TIME",
        DUCKDB_TYPE_TIME_NS.rawValue: "TIME_NS",
        DUCKDB_TYPE_TIME_TZ.rawValue: "TIME WITH TIME ZONE",
        DUCKDB_TYPE_TIMESTAMP.rawValue: "TIMESTAMP",
        DUCKDB_TYPE_TIMESTAMP_S.rawValue: "TIMESTAMP_S",
        DUCKDB_TYPE_TIMESTAMP_MS.rawValue: "TIMESTAMP_MS",
        DUCKDB_TYPE_TIMESTAMP_NS.rawValue: "TIMESTAMP_NS",
        DUCKDB_TYPE_TIMESTAMP_TZ.rawValue: "TIMESTAMP WITH TIME ZONE",
        DUCKDB_TYPE_INTERVAL.rawValue: "INTERVAL",
        DUCKDB_TYPE_UUID.rawValue: "UUID",
        DUCKDB_TYPE_BIT.rawValue: "BIT",
        DUCKDB_TYPE_BIGNUM.rawValue: "BIGNUM",
        DUCKDB_TYPE_SQLNULL.rawValue: "\"NULL\"",
        DUCKDB_TYPE_GEOMETRY.rawValue: "GEOMETRY",
        DUCKDB_TYPE_VARIANT.rawValue: "VARIANT",
    ]

    /// DuckDB quotes a member name unless it is a plain identifier (letters, digits after the first
    /// character, underscores) that is not a keyword.
    private static func memberName(_ name: String, keywords: Set<String>) -> String {
        let plain = !name.isEmpty && !keywords.contains(name.lowercased()) && name.unicodeScalars.enumerated().allSatisfy { index, scalar in
            scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || (index > 0 && ("0"..."9").contains(scalar))
        }
        return plain ? name : "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    var isNumeric: Bool {
        switch id {
        case DUCKDB_TYPE_TINYINT, DUCKDB_TYPE_SMALLINT, DUCKDB_TYPE_INTEGER, DUCKDB_TYPE_BIGINT,
             DUCKDB_TYPE_UTINYINT, DUCKDB_TYPE_USMALLINT, DUCKDB_TYPE_UINTEGER, DUCKDB_TYPE_UBIGINT,
             DUCKDB_TYPE_HUGEINT, DUCKDB_TYPE_UHUGEINT, DUCKDB_TYPE_FLOAT, DUCKDB_TYPE_DOUBLE,
             DUCKDB_TYPE_DECIMAL, DUCKDB_TYPE_BIGNUM:
            return true
        default:
            return false
        }
    }

    /// Types whose text Foxlume Query produces itself; the decoder's output for them is tested against DuckDB's own cast.
    var isDecodedNatively: Bool {
        switch id {
        case DUCKDB_TYPE_BOOLEAN, DUCKDB_TYPE_TINYINT, DUCKDB_TYPE_SMALLINT, DUCKDB_TYPE_INTEGER, DUCKDB_TYPE_BIGINT,
             DUCKDB_TYPE_UTINYINT, DUCKDB_TYPE_USMALLINT, DUCKDB_TYPE_UINTEGER, DUCKDB_TYPE_UBIGINT,
             DUCKDB_TYPE_HUGEINT, DUCKDB_TYPE_UHUGEINT, DUCKDB_TYPE_FLOAT, DUCKDB_TYPE_DOUBLE, DUCKDB_TYPE_DECIMAL,
             DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_BLOB, DUCKDB_TYPE_DATE, DUCKDB_TYPE_TIME, DUCKDB_TYPE_TIMESTAMP,
             DUCKDB_TYPE_INTERVAL, DUCKDB_TYPE_SQLNULL:
            return true
        default:
            return false
        }
    }
}
