import Foundation

/// Names for the built-in type OIDs that appear in RowDescription. The OIDs are fixed in `pg_type.dat`.
enum PostgresType {
    private static let names: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 22: "int2vector",
        23: "int4", 24: "regproc", 25: "text", 26: "oid", 27: "tid", 28: "xid", 29: "cid", 30: "oidvector",
        114: "json", 142: "xml", 194: "pg_node_tree",
        600: "point", 601: "lseg", 602: "path", 603: "box", 604: "polygon", 628: "line", 718: "circle",
        650: "cidr", 700: "float4", 701: "float8", 705: "unknown",
        774: "macaddr8", 790: "money", 829: "macaddr", 869: "inet", 1033: "aclitem",
        1042: "bpchar", 1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp",
        1184: "timestamptz", 1186: "interval", 1266: "timetz", 1560: "bit", 1562: "varbit",
        1700: "numeric", 1790: "refcursor",
        2202: "regprocedure", 2203: "regoper", 2204: "regoperator", 2205: "regclass", 2206: "regtype",
        2249: "record", 2275: "cstring", 2278: "void", 2950: "uuid", 3220: "pg_lsn",
        3614: "tsvector", 3615: "tsquery", 3734: "regconfig", 3802: "jsonb",
        3904: "int4range", 3906: "numrange", 3908: "tsrange", 3910: "tstzrange", 3912: "daterange", 3926: "int8range",
        4072: "jsonpath", 4089: "regnamespace", 4096: "regrole", 5069: "xid8",
    ]

    /// Array type OID to element type OID.
    private static let arrayElements: [UInt32: UInt32] = [
        1000: 16, 1001: 17, 1002: 18, 1003: 19, 1016: 20, 1005: 21, 1006: 22, 1007: 23, 1008: 24,
        1009: 25, 1028: 26, 1010: 27, 1011: 28, 1012: 29, 1013: 30, 199: 114, 143: 142,
        1017: 600, 1018: 601, 1019: 602, 1020: 603, 1027: 604, 629: 628, 719: 718,
        651: 650, 1021: 700, 1022: 701, 775: 774, 791: 790, 1040: 829, 1041: 869, 1034: 1033,
        1014: 1042, 1015: 1043, 1182: 1082, 1183: 1083, 1115: 1114, 1185: 1184, 1187: 1186,
        1270: 1266, 1561: 1560, 1563: 1562, 1231: 1700, 2201: 1790,
        2207: 2202, 2208: 2203, 2209: 2204, 2210: 2205, 2211: 2206, 2287: 2249, 1263: 2275,
        2951: 2950, 3221: 3220, 3643: 3614, 3645: 3615, 3735: 3734, 3807: 3802,
        3905: 3904, 3907: 3906, 3909: 3908, 3911: 3910, 3913: 3912, 3927: 3926,
        4073: 4072, 4090: 4089, 4097: 4096, 271: 5069,
    ]

    private static let numericOIDs: Set<UInt32> = [20, 21, 23, 26, 700, 701, 790, 1700]

    /// `int4`, `text[]`, or `oid:<n>` for types without a fixed OID (enums, domains, extensions).
    static func name(oid: UInt32) -> String {
        if let name = names[oid] { return name }
        if let element = arrayElements[oid], let name = names[element] { return name + "[]" }
        return "oid:\(oid)"
    }

    static func isNumeric(oid: UInt32) -> Bool {
        numericOIDs.contains(oid)
    }
}
