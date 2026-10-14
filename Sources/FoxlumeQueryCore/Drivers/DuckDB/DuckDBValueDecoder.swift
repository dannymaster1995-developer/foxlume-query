import CDuckDB
import Foundation

/// One vector of a data chunk with its data and validity pointers resolved once.
struct DuckDBVectorView {
    let vector: duckdb_vector
    let type: DuckDBType
    let data: UnsafeMutableRawPointer?
    let validity: UnsafeMutablePointer<UInt64>?

    init(_ vector: duckdb_vector, type: DuckDBType) {
        self.vector = vector
        self.type = type
        data = duckdb_vector_get_data(vector)
        validity = duckdb_vector_get_validity(vector)
    }

    /// STRUCT, UNION and ARRAY vectors keep their values in child vectors and have no data of their own.
    var hasData: Bool {
        data != nil || type.id == DUCKDB_TYPE_STRUCT || type.id == DUCKDB_TYPE_UNION || type.id == DUCKDB_TYPE_ARRAY
    }

    /// A NULL validity pointer means every row is valid.
    func isValid(_ row: Int) -> Bool {
        guard let validity else { return true }
        return validity[row >> 6] & (1 << UInt64(row & 63)) != 0
    }

    /// Callers check `hasData` first and never load from STRUCT, UNION or ARRAY vectors directly.
    func load<T>(_ row: Int, as: T.Type) -> T {
        guard let data else { preconditionFailure("Read from a DuckDB vector without data") }
        return data.load(fromByteOffset: row * MemoryLayout<T>.stride, as: T.self)
    }

    /// `duckdb_string_t` is 16 bytes: a 32-bit length, then up to 12 inline bytes or a 4-byte prefix and a pointer.
    func bytes(_ row: Int) -> UnsafeBufferPointer<UInt8> {
        guard let data else { return UnsafeBufferPointer(start: nil, count: 0) }
        let base = data + row * 16
        let length = Int(base.load(as: UInt32.self))
        if length <= 12 {
            return UnsafeBufferPointer(start: (base + 4).assumingMemoryBound(to: UInt8.self), count: length)
        }
        let pointer = base.load(fromByteOffset: 8, as: UnsafePointer<UInt8>.self)
        return UnsafeBufferPointer(start: pointer, count: length)
    }

    func string(_ row: Int) -> String {
        String(decoding: bytes(row), as: UTF8.self)
    }

    func child(_ index: Int, type: DuckDBType) -> DuckDBVectorView? {
        let child: duckdb_vector?
        switch self.type.id {
        case DUCKDB_TYPE_LIST, DUCKDB_TYPE_MAP: child = duckdb_list_vector_get_child(vector)
        case DUCKDB_TYPE_ARRAY: child = duckdb_array_vector_get_child(vector)
        default: child = duckdb_struct_vector_get_child(vector, idx_t(index))
        }
        return child.map { DuckDBVectorView($0, type: type) }
    }
}

/// Turns DuckDB vectors into grid cells.
///
/// Scalar types are formatted here exactly as `CAST(x AS VARCHAR)` formats them (tests compare the two).
/// Other types reach the decoder already cast to VARCHAR by the connection's SELECT projection; for statements
/// that cannot be wrapped (DML with RETURNING, EXECUTE, CALL) they go through DuckDB's value API instead.
enum DuckDBValueDecoder {
    static func cell(_ view: DuckDBVectorView, row: Int) -> CellValue {
        guard view.isValid(row), view.hasData else { return .null }
        let type = view.type
        switch type.id {
        case DUCKDB_TYPE_SQLNULL: return .null
        case DUCKDB_TYPE_BOOLEAN: return .text(view.load(row, as: UInt8.self) != 0 ? "true" : "false")
        case DUCKDB_TYPE_TINYINT: return .text(String(view.load(row, as: Int8.self)))
        case DUCKDB_TYPE_SMALLINT: return .text(String(view.load(row, as: Int16.self)))
        case DUCKDB_TYPE_INTEGER: return .text(String(view.load(row, as: Int32.self)))
        case DUCKDB_TYPE_BIGINT: return .text(String(view.load(row, as: Int64.self)))
        case DUCKDB_TYPE_UTINYINT: return .text(String(view.load(row, as: UInt8.self)))
        case DUCKDB_TYPE_USMALLINT: return .text(String(view.load(row, as: UInt16.self)))
        case DUCKDB_TYPE_UINTEGER: return .text(String(view.load(row, as: UInt32.self)))
        case DUCKDB_TYPE_UBIGINT: return .text(String(view.load(row, as: UInt64.self)))
        case DUCKDB_TYPE_HUGEINT:
            let value = view.load(row, as: duckdb_hugeint.self)
            return .text(DuckDBText.integer(upper: value.upper, lower: value.lower))
        case DUCKDB_TYPE_UHUGEINT:
            let value = view.load(row, as: duckdb_uhugeint.self)
            return .text(DuckDBText.unsigned(high: value.upper, low: value.lower))
        case DUCKDB_TYPE_FLOAT: return .text(DuckDBText.float(view.load(row, as: Float.self)))
        case DUCKDB_TYPE_DOUBLE: return .text(DuckDBText.double(view.load(row, as: Double.self)))
        case DUCKDB_TYPE_DECIMAL: return .text(decimal(view, row: row))
        case DUCKDB_TYPE_VARCHAR: return .text(view.string(row))
        case DUCKDB_TYPE_BLOB:
            let bytes = view.bytes(row)
            return .bytes(bytes.isEmpty ? Data() : Data(buffer: bytes))
        case DUCKDB_TYPE_DATE: return .text(DuckDBText.date(view.load(row, as: duckdb_date.self)))
        case DUCKDB_TYPE_TIME: return .text(DuckDBText.time(micros: view.load(row, as: Int64.self)))
        case DUCKDB_TYPE_TIMESTAMP: return .text(DuckDBText.timestamp(view.load(row, as: duckdb_timestamp.self)))
        case DUCKDB_TYPE_INTERVAL: return .text(DuckDBText.interval(view.load(row, as: duckdb_interval.self)))
        default:
            return castThroughValueAPI(view, row: row).map(CellValue.text) ?? .text("<\(type.name(keywords: []))>")
        }
    }

    private static func decimal(_ view: DuckDBVectorView, row: Int) -> String {
        let integer: String
        switch view.type.storage {
        case DUCKDB_TYPE_SMALLINT: integer = String(view.load(row, as: Int16.self))
        case DUCKDB_TYPE_INTEGER: integer = String(view.load(row, as: Int32.self))
        case DUCKDB_TYPE_BIGINT: integer = String(view.load(row, as: Int64.self))
        default:
            let value = view.load(row, as: duckdb_hugeint.self)
            integer = DuckDBText.integer(upper: value.upper, lower: value.lower)
        }
        return DuckDBText.decimal(integer, scale: Int(view.type.decimalScale), width: Int(view.type.decimalWidth))
    }

    // MARK: - Value API

    /// DuckDB's own text for the value, through `duckdb_get_varchar` (its default cast to VARCHAR).
    static func castThroughValueAPI(_ view: DuckDBVectorView, row: Int) -> String? {
        var value = makeValue(view, row: row)
        defer { duckdb_destroy_value(&value) }
        guard let value else { return nil }
        return DuckDBType.takeString(duckdb_get_varchar(value))
    }

    /// Builds a `duckdb_value` for one row, recursing into nested vectors. Nil for types the C API cannot build.
    static func makeValue(_ view: DuckDBVectorView, row: Int) -> duckdb_value? {
        guard view.isValid(row), view.hasData else { return duckdb_create_null_value() }
        let type = view.type
        switch type.id {
        case DUCKDB_TYPE_BOOLEAN: return duckdb_create_bool(view.load(row, as: UInt8.self) != 0)
        case DUCKDB_TYPE_TINYINT: return duckdb_create_int8(view.load(row, as: Int8.self))
        case DUCKDB_TYPE_SMALLINT: return duckdb_create_int16(view.load(row, as: Int16.self))
        case DUCKDB_TYPE_INTEGER: return duckdb_create_int32(view.load(row, as: Int32.self))
        case DUCKDB_TYPE_BIGINT: return duckdb_create_int64(view.load(row, as: Int64.self))
        case DUCKDB_TYPE_UTINYINT: return duckdb_create_uint8(view.load(row, as: UInt8.self))
        case DUCKDB_TYPE_USMALLINT: return duckdb_create_uint16(view.load(row, as: UInt16.self))
        case DUCKDB_TYPE_UINTEGER: return duckdb_create_uint32(view.load(row, as: UInt32.self))
        case DUCKDB_TYPE_UBIGINT: return duckdb_create_uint64(view.load(row, as: UInt64.self))
        case DUCKDB_TYPE_HUGEINT: return duckdb_create_hugeint(view.load(row, as: duckdb_hugeint.self))
        case DUCKDB_TYPE_UHUGEINT: return duckdb_create_uhugeint(view.load(row, as: duckdb_uhugeint.self))
        case DUCKDB_TYPE_FLOAT: return duckdb_create_float(view.load(row, as: Float.self))
        case DUCKDB_TYPE_DOUBLE: return duckdb_create_double(view.load(row, as: Double.self))
        case DUCKDB_TYPE_DECIMAL:
            let stored: duckdb_hugeint
            switch type.storage {
            case DUCKDB_TYPE_SMALLINT: stored = hugeint(Int64(view.load(row, as: Int16.self)))
            case DUCKDB_TYPE_INTEGER: stored = hugeint(Int64(view.load(row, as: Int32.self)))
            case DUCKDB_TYPE_BIGINT: stored = hugeint(view.load(row, as: Int64.self))
            default: stored = view.load(row, as: duckdb_hugeint.self)
            }
            return duckdb_create_decimal(duckdb_decimal(width: type.decimalWidth, scale: type.decimalScale, value: stored))
        case DUCKDB_TYPE_VARCHAR:
            let bytes = view.bytes(row)
            guard let start = bytes.baseAddress, !bytes.isEmpty else { return duckdb_create_varchar("") }
            return start.withMemoryRebound(to: CChar.self, capacity: bytes.count) { duckdb_create_varchar_length($0, idx_t(bytes.count)) }
        case DUCKDB_TYPE_BLOB:
            let bytes = view.bytes(row)
            return duckdb_create_blob(bytes.baseAddress ?? UnsafePointer(bitPattern: 1), idx_t(bytes.count))
        case DUCKDB_TYPE_BIT:
            let bytes = view.bytes(row)
            return duckdb_create_bit(duckdb_bit(data: UnsafeMutablePointer(mutating: bytes.baseAddress), size: idx_t(bytes.count)))
        case DUCKDB_TYPE_BIGNUM:
            return bignum(view.bytes(row))
        case DUCKDB_TYPE_DATE: return duckdb_create_date(view.load(row, as: duckdb_date.self))
        case DUCKDB_TYPE_TIME: return duckdb_create_time(view.load(row, as: duckdb_time.self))
        case DUCKDB_TYPE_TIME_NS: return duckdb_create_time_ns(view.load(row, as: duckdb_time_ns.self))
        case DUCKDB_TYPE_TIME_TZ: return duckdb_create_time_tz_value(view.load(row, as: duckdb_time_tz.self))
        case DUCKDB_TYPE_TIMESTAMP: return duckdb_create_timestamp(view.load(row, as: duckdb_timestamp.self))
        case DUCKDB_TYPE_TIMESTAMP_TZ: return duckdb_create_timestamp_tz(view.load(row, as: duckdb_timestamp.self))
        case DUCKDB_TYPE_TIMESTAMP_S: return duckdb_create_timestamp_s(view.load(row, as: duckdb_timestamp_s.self))
        case DUCKDB_TYPE_TIMESTAMP_MS: return duckdb_create_timestamp_ms(view.load(row, as: duckdb_timestamp_ms.self))
        case DUCKDB_TYPE_TIMESTAMP_NS: return duckdb_create_timestamp_ns(view.load(row, as: duckdb_timestamp_ns.self))
        case DUCKDB_TYPE_INTERVAL: return duckdb_create_interval(view.load(row, as: duckdb_interval.self))
        case DUCKDB_TYPE_UUID:
            // Vectors store UUIDs with the top bit flipped so they sort as signed integers; the value API takes the plain bits.
            let stored = view.load(row, as: duckdb_hugeint.self)
            return duckdb_create_uuid(duckdb_uhugeint(lower: stored.lower, upper: UInt64(bitPattern: stored.upper) ^ (1 << 63)))
        case DUCKDB_TYPE_ENUM:
            let index: UInt64
            switch type.storage {
            case DUCKDB_TYPE_UTINYINT: index = UInt64(view.load(row, as: UInt8.self))
            case DUCKDB_TYPE_USMALLINT: index = UInt64(view.load(row, as: UInt16.self))
            default: index = UInt64(view.load(row, as: UInt32.self))
            }
            return duckdb_create_enum_value(type.handle, index)
        case DUCKDB_TYPE_LIST, DUCKDB_TYPE_ARRAY:
            guard let elementType = type.members.first?.type, let child = view.child(0, type: elementType) else { return nil }
            let range: Range<Int>
            if type.id == DUCKDB_TYPE_LIST {
                let entry = view.load(row, as: duckdb_list_entry.self)
                range = Int(entry.offset)..<Int(entry.offset + entry.length)
            } else {
                range = (row * type.arraySize)..<((row + 1) * type.arraySize)
            }
            return withValues(range.map { makeValue(child, row: $0) }) { values in
                type.id == DUCKDB_TYPE_LIST
                    ? duckdb_create_list_value(elementType.handle, values, idx_t(range.count))
                    : duckdb_create_array_value(elementType.handle, values, idx_t(range.count))
            }
        case DUCKDB_TYPE_MAP:
            guard type.members.count == 2,
                  let entries = duckdb_list_vector_get_child(view.vector),
                  let keyVector = duckdb_struct_vector_get_child(entries, 0),
                  let valueVector = duckdb_struct_vector_get_child(entries, 1) else { return nil }
            let keys = DuckDBVectorView(keyVector, type: type.members[0].type)
            let values = DuckDBVectorView(valueVector, type: type.members[1].type)
            let entry = view.load(row, as: duckdb_list_entry.self)
            let range = Int(entry.offset)..<Int(entry.offset + entry.length)
            return withValues(range.map { makeValue(keys, row: $0) }) { keyValues in
                withValues(range.map { makeValue(values, row: $0) }) { valueValues in
                    duckdb_create_map_value(type.handle, keyValues, valueValues, idx_t(range.count))
                }
            }
        case DUCKDB_TYPE_STRUCT:
            let fields = type.members.enumerated().map { index, member in
                view.child(index, type: member.type).flatMap { makeValue($0, row: row) }
            }
            return withValues(fields) { duckdb_create_struct_value(type.handle, $0) }
        case DUCKDB_TYPE_UNION:
            // A UNION vector is a struct whose first child holds the tag of the active member.
            guard let tagVector = duckdb_struct_vector_get_child(view.vector, 0), let tagData = duckdb_vector_get_data(tagVector) else { return nil }
            let tag = Int(tagData.load(fromByteOffset: row, as: UInt8.self))
            guard type.members.indices.contains(tag), let member = view.child(tag + 1, type: type.members[tag].type) else { return nil }
            var value = makeValue(member, row: row)
            defer { duckdb_destroy_value(&value) }
            guard let value else { return nil }
            return duckdb_create_union_value(type.handle, idx_t(tag), value)
        default:
            return nil
        }
    }

    /// Vectors store a BIGNUM as a 3-byte header (top bit set for non-negative numbers) followed by the
    /// big-endian magnitude, with every byte inverted when the number is negative.
    private static func bignum(_ stored: UnsafeBufferPointer<UInt8>) -> duckdb_value? {
        guard stored.count > 3 else { return nil }
        let negative = stored[0] & 0x80 == 0
        var magnitude = Array(stored[3...])
        if negative {
            for index in magnitude.indices { magnitude[index] = ~magnitude[index] }
        }
        return magnitude.withUnsafeMutableBufferPointer { buffer in
            duckdb_create_bignum(duckdb_bignum(data: buffer.baseAddress, size: idx_t(buffer.count), is_negative: negative))
        }
    }

    private static func hugeint(_ value: Int64) -> duckdb_hugeint {
        duckdb_hugeint(lower: UInt64(bitPattern: value), upper: value < 0 ? -1 : 0)
    }

    /// Passes the values to `body` and destroys them afterwards. Fails when any element could not be built.
    private static func withValues(_ values: [duckdb_value?], _ body: (UnsafeMutablePointer<duckdb_value?>) -> duckdb_value?) -> duckdb_value? {
        var owned = values
        defer {
            for index in owned.indices where owned[index] != nil {
                duckdb_destroy_value(&owned[index])
            }
        }
        guard !owned.contains(where: { $0 == nil }) else { return nil }
        if owned.isEmpty {
            var placeholder: duckdb_value? = nil
            return body(&placeholder)
        }
        return owned.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return body(base)
        }
    }
}

/// DuckDB's text formats for the types Foxlume Query decodes natively.
enum DuckDBText {
    /// Two's complement 128-bit integer as decimal text.
    static func integer(upper: Int64, lower: UInt64) -> String {
        guard upper < 0 else { return unsigned(high: UInt64(upper), low: lower) }
        let low = ~lower &+ 1
        let high = ~UInt64(bitPattern: upper) &+ (low == 0 ? 1 : 0)
        return "-" + unsigned(high: high, low: low)
    }

    static func unsigned(high: UInt64, low: UInt64) -> String {
        guard high != 0 else { return String(low) }
        let chunk: UInt64 = 10_000_000_000_000_000_000
        var high = high
        var low = low
        var chunks: [UInt64] = []
        while high != 0 {
            let (quotientHigh, remainderHigh) = high.quotientAndRemainder(dividingBy: chunk)
            let (quotientLow, remainder) = chunk.dividingFullWidth((high: remainderHigh, low: low))
            chunks.append(remainder)
            high = quotientHigh
            low = quotientLow
        }
        // The value is at least 2^64, so the final quotient is non-zero and leads the text.
        var text = String(low)
        for value in chunks.reversed() {
            let digits = String(value)
            text += String(repeating: "0", count: 19 - digits.count) + digits
        }
        return text
    }

    /// Places the decimal point `scale` digits from the right of an integer's text. DuckDB writes a leading
    /// zero only when the type has integer digits, so `DECIMAL(4,4)` reads `.5000` but `DECIMAL(4,3)` reads `0.500`.
    static func decimal(_ integer: String, scale: Int, width: Int) -> String {
        guard scale > 0 else { return integer }
        let negative = integer.hasPrefix("-")
        var digits = negative ? String(integer.dropFirst()) : integer
        let minimum = width > scale ? scale + 1 : scale
        if digits.count < minimum {
            digits = String(repeating: "0", count: minimum - digits.count) + digits
        }
        let point = digits.index(digits.endIndex, offsetBy: -scale)
        return (negative ? "-" : "") + digits[..<point] + "." + digits[point...]
    }

    static func double(_ value: Double) -> String {
        shortest(value.description, finite: value.isFinite, exponentLimit: 16)
    }

    static func float(_ value: Float) -> String {
        shortest(value.description, finite: value.isFinite, exponentLimit: 16)
    }

    /// Re-spells Swift's shortest round-trip digits the way DuckDB's formatter writes them:
    /// plain notation with at least one decimal, switching to `1e+16` style outside `1e-5 ..< 1e16`.
    private static func shortest(_ swift: String, finite: Bool, exponentLimit: Int) -> String {
        guard finite else { return swift }
        var text = Substring(swift)
        let negative = text.hasPrefix("-")
        if negative { text = text.dropFirst() }
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = text[..<e]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? "0"
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        var digits = whole + fraction
        var pointPosition = whole.count + exponent
        let leadingZeros = digits.prefix { $0 == "0" }.count
        if leadingZeros == digits.count {
            return (negative ? "-" : "") + "0.0"
        }
        digits.removeFirst(leadingZeros)
        pointPosition -= leadingZeros
        while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }

        let decimalExponent = pointPosition - 1
        let sign = negative ? "-" : ""
        if decimalExponent < -4 || decimalExponent >= exponentLimit {
            let mantissa = digits.count > 1 ? String(digits.prefix(1)) + "." + digits.dropFirst() : digits
            let exponentDigits = String(abs(decimalExponent))
            let paddedExponent = exponentDigits.count < 2 ? "0" + exponentDigits : exponentDigits
            return sign + mantissa + "e" + (decimalExponent < 0 ? "-" : "+") + paddedExponent
        }
        if pointPosition <= 0 {
            return sign + "0." + String(repeating: "0", count: -pointPosition) + digits
        }
        if pointPosition >= digits.count {
            return sign + digits + String(repeating: "0", count: pointPosition - digits.count) + ".0"
        }
        let point = digits.index(digits.startIndex, offsetBy: pointPosition)
        return sign + digits[..<point] + "." + digits[point...]
    }

    static func date(_ date: duckdb_date) -> String {
        guard duckdb_is_finite_date(date) else { return date.days > 0 ? "infinity" : "-infinity" }
        let parts = duckdb_from_date(date)
        let (year, bc) = era(parts.year)
        return "\(pad(year, 4))-\(pad(Int(parts.month), 2))-\(pad(Int(parts.day), 2))" + (bc ? " (BC)" : "")
    }

    static func time(micros: Int64) -> String {
        let parts = duckdb_from_time(duckdb_time(micros: micros))
        return clock(hour: Int(parts.hour), minute: Int(parts.min), second: Int(parts.sec), micros: Int(parts.micros))
    }

    static func timestamp(_ timestamp: duckdb_timestamp) -> String {
        guard duckdb_is_finite_timestamp(timestamp) else { return timestamp.micros > 0 ? "infinity" : "-infinity" }
        let parts = duckdb_from_timestamp(timestamp)
        let (year, bc) = era(parts.date.year)
        let day = "\(pad(year, 4))-\(pad(Int(parts.date.month), 2))-\(pad(Int(parts.date.day), 2))"
        let time = clock(hour: Int(parts.time.hour), minute: Int(parts.time.min), second: Int(parts.time.sec), micros: Int(parts.time.micros))
        return day + (bc ? " (BC) " : " ") + time
    }

    static func interval(_ interval: duckdb_interval) -> String {
        var parts: [String] = []
        if interval.months != 0 {
            let years = interval.months / 12
            let months = interval.months - years * 12
            if years != 0 { parts.append(unit(years, "year")) }
            if months != 0 { parts.append(unit(months, "month")) }
        }
        if interval.days != 0 { parts.append(unit(interval.days, "day")) }
        if interval.micros != 0 {
            let magnitude = interval.micros.magnitude
            let hours = magnitude / 3_600_000_000
            let rest = magnitude % 3_600_000_000
            let text = (hours < 10 ? "0" : "") + String(hours) + ":" + pad(Int(rest / 60_000_000), 2) + ":" + pad(Int(rest % 60_000_000 / 1_000_000), 2) + fraction(Int(rest % 1_000_000))
            parts.append((interval.micros < 0 ? "-" : "") + text)
        }
        return parts.isEmpty ? "00:00:00" : parts.joined(separator: " ")
    }

    private static func unit(_ count: Int32, _ name: String) -> String {
        "\(count) \(name)" + (count == 1 || count == -1 ? "" : "s")
    }

    /// DuckDB counts years astronomically (0 is 1 BC) and prints BC years with a suffix.
    private static func era(_ year: Int32) -> (Int, Bool) {
        year <= 0 ? (Int(-year) + 1, true) : (Int(year), false)
    }

    private static func clock(hour: Int, minute: Int, second: Int, micros: Int) -> String {
        "\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))" + fraction(micros)
    }

    /// Microseconds as `.ffffff` without trailing zeros, or nothing.
    private static func fraction(_ micros: Int) -> String {
        guard micros != 0 else { return "" }
        var digits = pad(micros, 6)
        while digits.hasSuffix("0") { digits.removeLast() }
        return "." + digits
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
