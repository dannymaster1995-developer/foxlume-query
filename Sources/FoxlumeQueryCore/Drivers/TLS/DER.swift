import Foundation

/// A minimal DER reader, enough for private keys (PKCS#1, PKCS#8, SEC1), PBES2 parameters and the parts of a
/// certificate that TLS verification needs (subject alternative names).
struct DERNode {
    let tag: UInt8
    let content: [UInt8]

    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let oid: UInt8 = 0x06
    static let sequence: UInt8 = 0x30

    var isConstructed: Bool { tag & 0x20 != 0 }

    /// The elements inside a constructed node (a SEQUENCE, a SET or a constructed context tag).
    func children() throws -> [DERNode] {
        try DER.parseAll(content)
    }

    func child(_ index: Int) throws -> DERNode {
        let all = try children()
        guard index < all.count else { throw DERError("missing element \(index)") }
        return all[index]
    }

    /// Dotted form of an OBJECT IDENTIFIER, for example `1.2.840.113549.1.1.1`.
    var objectIdentifier: String? {
        guard tag == Self.oid, let first = content.first else { return nil }
        var parts = [String(first / 40), String(first % 40)]
        var value: UInt64 = 0
        for byte in content.dropFirst() {
            value = (value << 7) | UInt64(byte & 0x7f)
            if byte & 0x80 == 0 {
                parts.append(String(value))
                value = 0
            }
        }
        return parts.joined(separator: ".")
    }

    /// A small non-negative INTEGER (iteration counts, key lengths, versions).
    var intValue: Int? {
        guard tag == Self.integer, !content.isEmpty, content.count <= 8, content[0] & 0x80 == 0 else { return nil }
        return content.reduce(0) { ($0 << 8) | Int($1) }
    }
}

struct DERError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum DER {
    /// Exactly one element; trailing bytes are an error.
    static func parse(_ bytes: [UInt8]) throws -> DERNode {
        var offset = 0
        let node = try read(bytes, at: &offset)
        guard offset == bytes.count else { throw DERError("trailing data after the DER structure") }
        return node
    }

    static func parseAll(_ bytes: [UInt8]) throws -> [DERNode] {
        var offset = 0
        var nodes: [DERNode] = []
        while offset < bytes.count {
            nodes.append(try read(bytes, at: &offset))
        }
        return nodes
    }

    private static func read(_ bytes: [UInt8], at offset: inout Int) throws -> DERNode {
        guard offset + 2 <= bytes.count else { throw DERError("truncated DER element") }
        let tag = bytes[offset]
        guard tag & 0x1f != 0x1f else { throw DERError("high tag numbers are not supported") }
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw DERError("bad DER length") }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard length >= 0, offset + length <= bytes.count else { throw DERError("DER length runs past the end") }
        let content = Array(bytes[offset..<(offset + length)])
        offset += length
        return DERNode(tag: tag, content: content)
    }
}

/// One `-----BEGIN …-----` block of a PEM file, with its RFC 1421 headers (`Proc-Type`, `DEK-Info`).
struct PEMBlock {
    let label: String
    let headers: [String: String]
    let der: [UInt8]

    /// Every block in the text, in order. Text outside blocks (comments, `Bag Attributes`) is ignored.
    static func all(in text: String) -> [PEMBlock] {
        var blocks: [PEMBlock] = []
        var label: String?
        var headers: [String: String] = [:]
        var body = ""
        var inHeaders = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let current = label {
                if line.hasPrefix("-----END ") {
                    if let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) {
                        blocks.append(PEMBlock(label: current, headers: headers, der: [UInt8](data)))
                    }
                    label = nil
                    continue
                }
                if inHeaders {
                    if line.isEmpty {
                        inHeaders = false
                        continue
                    }
                    if let colon = line.firstIndex(of: ":") {
                        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                        headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        continue
                    }
                    inHeaders = false
                }
                body += line
            } else if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                label = String(line.dropFirst(11).dropLast(5))
                headers = [:]
                body = ""
                inHeaders = true
            }
        }
        return blocks
    }
}
