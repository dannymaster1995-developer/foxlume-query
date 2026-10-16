import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct ValueViewerTests {
    // MARK: Magic bytes

    private func bytes(_ values: [UInt8], padTo count: Int = 32) -> Data {
        Data(values + Array(repeating: 0, count: max(0, count - values.count)))
    }

    @Test func detectsImageSignatures() {
        #expect(ImageFormat.detect(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
        #expect(ImageFormat.detect(bytes([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ImageFormat.detect(Data("GIF89a".utf8)) == .gif)
        #expect(ImageFormat.detect(Data("GIF87a".utf8)) == .gif)
        #expect(ImageFormat.detect(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == .webp)
        #expect(ImageFormat.detect(Data("\u{0}\u{0}\u{0}\u{18}ftypheic\u{0}\u{0}\u{0}\u{0}".utf8)) == .heic)
        #expect(ImageFormat.detect(Data("\u{0}\u{0}\u{0}\u{18}ftypmif1".utf8)) == .heic)
        #expect(ImageFormat.detect(bytes([0x49, 0x49, 0x2A, 0x00])) == .tiff)
        #expect(ImageFormat.detect(bytes([0x4D, 0x4D, 0x00, 0x2A])) == .tiff)
        #expect(ImageFormat.detect(Data("%PDF-1.7\n".utf8)) == .pdf)
        var bmp = [UInt8](repeating: 0, count: 54)
        bmp[0] = 0x42; bmp[1] = 0x4D; bmp[14] = 40
        #expect(ImageFormat.detect(Data(bmp)) == .bmp)
    }

    @Test func rejectsLookalikes() {
        #expect(ImageFormat.detect(Data()) == nil)
        #expect(ImageFormat.detect(Data([0x89, 0x50, 0x4E])) == nil, "too short for the PNG signature")
        #expect(ImageFormat.detect(Data("BM is not a bitmap without its header".utf8)) == nil)
        #expect(ImageFormat.detect(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)) == nil, "a WAV file")
        #expect(ImageFormat.detect(Data("\u{0}\u{0}\u{0}\u{18}ftypisom".utf8)) == nil, "an MP4 video")
        #expect(ImageFormat.detect(Data("hello world, plain text".utf8)) == nil)
        #expect(ImageFormat.png.fileExtension == "png" && ImageFormat.jpeg.fileExtension == "jpg")
    }

    @Test func binaryDataOfCells() {
        #expect(BinaryValue.data(of: .bytes(Data([1, 2])), typeName: "BLOB") == Data([1, 2]))
        #expect(BinaryValue.data(of: .text("\\x89504e47"), typeName: "bytea") == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(BinaryValue.data(of: .text("\\xFFfe"), typeName: "BYTEA") == Data([0xFF, 0xFE]))
        #expect(BinaryValue.data(of: .text("\\x"), typeName: "bytea") == Data())
        #expect(BinaryValue.data(of: .text("\\x89504e47"), typeName: "text") == nil, "only bytea text is hex")
        #expect(BinaryValue.data(of: .text("\\x8"), typeName: "bytea") == nil)
        #expect(BinaryValue.data(of: .text("\\xzz"), typeName: "bytea") == nil)
        #expect(BinaryValue.data(of: .text("abc"), typeName: "bytea") == nil, "escape output format")
        #expect(BinaryValue.data(of: .null, typeName: "bytea") == nil)
    }

    // MARK: View modes

    @Test func modesFollowTheContent() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])
        #expect(ValueViewMode.modes(for: .bytes(png), typeName: "BLOB") == ([.text, .image, .hex], .image))
        #expect(ValueViewMode.modes(for: .text("\\x" + png.hexString), typeName: "bytea") == ([.text, .image, .hex], .image))
        #expect(ValueViewMode.modes(for: .bytes(Data([0, 1, 2])), typeName: "BLOB") == ([.text, .hex], .hex), "no Image mode for other bytes")
        #expect(ValueViewMode.modes(for: .text(" {\"a\": [1, 2]}"), typeName: "jsonb") == ([.text, .json, .hex], .json))
        #expect(ValueViewMode.modes(for: .text("[1, 2"), typeName: "json") == ([.text, .hex], .text), "invalid JSON")
        #expect(ValueViewMode.modes(for: .text("\"just a string\""), typeName: "json") == ([.text, .hex], .text), "scalars have no tree")
        #expect(ValueViewMode.modes(for: .text("hello"), typeName: "text") == ([.text, .hex], .text))
        #expect(ValueViewMode.modes(for: .null, typeName: "jsonb") == ([.text], .text))
        #expect(ValueViewMode.modes(for: .expression("DEFAULT"), typeName: "bytea") == ([.text], .text))
        let big = Data(count: ValueViewMode.textModeByteLimit + 1)
        #expect(ValueViewMode.modes(for: .bytes(big), typeName: "LONGBLOB") == ([.hex], .hex), "large binary skips Text")
    }

    // MARK: Hex dump

    @Test func hexLines() {
        let data = Data((0..<20).map { UInt8($0) } + Array("AZ~".utf8) + [0x7f, 0xff])
        #expect(HexDump.lineCount(byteCount: 0) == 0)
        #expect(HexDump.lineCount(byteCount: 16) == 1)
        #expect(HexDump.lineCount(byteCount: data.count) == 2)
        let first = HexDump.line(0, of: data)
        #expect(first.offset == "00000000")
        #expect(first.hex == "00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f")
        #expect(first.hex.count == HexDump.hexColumnWidth)
        #expect(first.ascii == "................")
        let second = HexDump.line(1, of: data)
        #expect(second.offset == "00000010")
        #expect(second.hex == "10 11 12 13 41 5a 7e 7f  ff")
        #expect(second.ascii == "....AZ~..")
        #expect(HexDump.line(5, of: data) == HexDump.Line(offset: "00000050", hex: "", ascii: ""))
        // A slice keeps its own indices.
        let slice = data[4..<10]
        #expect(HexDump.line(0, of: slice).hex == "04 05 06 07 08 09")
    }

    @Test func hexOffsetsAndColumns() {
        #expect(HexDump.offsetDigits(byteCount: 0) == 8)
        #expect(HexDump.offsetDigits(byteCount: 0x1_0000_0000) == 8)
        #expect(HexDump.offsetDigits(byteCount: 0x1_0000_0001) == 9)
        #expect(HexDump.line(0, of: Data([1]), offsetDigits: 10).offset == "0000000000")
        #expect(HexDump.hexColumn(ofByte: 0) == 0)
        #expect(HexDump.hexColumn(ofByte: 7) == 21)
        #expect(HexDump.hexColumn(ofByte: 8) == 25)
        #expect(HexDump.hexColumn(ofByte: 15) == 46)
        for position in 0..<16 {
            let column = HexDump.hexColumn(ofByte: position)
            #expect(HexDump.byte(atHexColumn: column) == position)
            #expect(HexDump.byte(atHexColumn: column + 1) == position)
        }
        #expect(HexDump.byte(atHexColumn: 23) == 7, "the gap belongs to the byte before it")
        #expect(HexDump.byte(atHexColumn: 24) == 7)
        #expect(HexDump.byte(atHexColumn: 200) == 15)
        #expect(HexDump.byte(atHexColumn: -3) == 0)
    }

    @Test func hexSelectionText() {
        let data = Data([0xde, 0xad, 0xbe, 0xef])
        #expect(HexDump.hexString(of: data, range: 1..<3) == "adbe")
        #expect(HexDump.hexString(of: data, range: 2..<99) == "beef")
        #expect(HexDump.hexString(of: data[2...], range: 0..<1) == "be")
    }

    // MARK: JSON paths and tree

    @Test func paths() {
        #expect(JSONPath.string([]) == "$")
        #expect(JSONPath.string([.key("items"), .index(2), .key("name")]) == "$.items[2].name")
        #expect(JSONPath.string([.key("first name")]) == "$['first name']")
        #expect(JSONPath.string([.key("it's")]) == "$['it\\'s']")
        #expect(JSONPath.string([.key("a\\b")]) == "$['a\\\\b']")
        #expect(JSONPath.string([.key("2nd")]) == "$['2nd']")
        #expect(JSONPath.string([.key("")]) == "$['']")
        #expect(JSONPath.string([.key("_id"), .key("$oid")]) == "$._id.$oid")
        #expect(JSONPath.string([.index(0), .index(1)]) == "$[0][1]")
    }

    @Test func treeKeepsOrderAndTypes() throws {
        let text = """
            {"z": 1, "items": [{"name": "a"}, {"name": "b\\n\\"c\\""}, {"name": "\\u00fc\\ud83d\\ude00"}], "ok": true, "none": null, "pi": -3.14e2, "empty": {}, "list": []}
            """
        let document = try #require(JSONTreeDocument(text: text))
        let root = document.root
        #expect(root.kind == .object && root.label == "$" && root.path == "$")
        #expect(root.children.map(\.label) == ["z", "items", "ok", "none", "pi", "empty", "list"], "text order, not sorted")
        #expect(root.children.map(\.kind) == [.number, .array, .boolean, .null, .number, .object, .array])
        #expect(root.summary == "{7 keys}")
        let items = root.children[1]
        #expect(items.summary == "[3 items]")
        #expect(items.children.map(\.label) == ["[0]", "[1]", "[2]"])
        let name = items.children[1].children[0]
        #expect(name.path == "$.items[1].name")
        #expect(name.summary == "b\n\"c\"")
        #expect(name.copyText == "b\n\"c\"")
        #expect(name.rawText == "\"b\\n\\\"c\\\"\"")
        #expect(items.children[2].children[0].stringValue == "ü😀")
        #expect(items.children[0].copyText == "{\"name\": \"a\"}", "containers copy as their JSON")
        #expect(root.children[4].copyText == "-3.14e2")
        #expect(root.children[5].summary == "{0 keys}" && root.children[6].summary == "[0 items]")
        #expect(root.children[0].children.isEmpty && root.children[0].childCount == 0)
        let nested = try #require(JSONTreeDocument(text: "[1, [2, [3]]]"))
        #expect(nested.root.children[1].children[1].path == "$[1][1]")
    }

    @Test func validation() {
        for valid in ["{}", "[]", " [1, -0, 0.5, 1e10, 2E-3, \"x\", true, false, null] ", "{\"a\":{\"b\":[{}]}}", "[\"\\u0041\\/\"]"] {
            #expect(JSONTreeDocument.isTree(valid), "\(valid)")
        }
        for invalid in ["", "1", "\"s\"", "null", "{", "[1,]", "{\"a\" 1}", "{a: 1}", "[01]", "[1.]", "[.5]", "[1e]", "[tru]",
                        "['x']", "[\"\\x\"]", "[\"\\u12\"]", "[\"a\nb\"]", "[1] x", "{\"a\":1,}", "[NaN]", "[-]"] {
            #expect(!JSONTreeDocument.isTree(invalid), "\(invalid)")
        }
        #expect(JSONTreeDocument.isTree(String(repeating: "[", count: 400) + String(repeating: "]", count: 400)))
        #expect(!JSONTreeDocument.isTree(String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)), "too deep")
    }

    @Test func search() throws {
        let document = try #require(JSONTreeDocument(text: """
            {"user": {"name": "Ada", "tags": ["admin", "ops"]}, "items": [{"name": "Widget"}, {"sku": "W-1"}], "count": 2}
            """))
        let root = document.root
        let byName = document.filter("name")
        #expect(byName.matchCount == 2)
        #expect(byName.children(of: root).map(\.label) == ["user", "items"])
        let user = root.children[0]
        #expect(byName.children(of: user).map(\.label) == ["name"])
        #expect(byName.children(of: root.children[1]).map(\.label) == ["[0]"])
        let byValue = document.filter("ADM")
        #expect(byValue.matchCount == 1)
        #expect(byValue.children(of: user).map(\.label) == ["tags"])
        #expect(byValue.children(of: user.children[1]).map(\.label) == ["[0]"])
        // A matching container shows everything inside it.
        let byKey = document.filter("user")
        #expect(byKey.isMatch(user))
        #expect(byKey.children(of: user).map(\.label) == ["name", "tags"])
        #expect(byKey.children(of: user.children[1]).count == 2)
        #expect(document.filter("nothing here").children(of: root).isEmpty)
        #expect(document.filter("2").children(of: root).map(\.label) == ["count"], "numbers match, array indexes do not")
    }

    @Test func largeDocumentReadsChildrenLazily() throws {
        let element = "{\"id\": 1, \"name\": \"row\", \"tags\": [\"a\", \"b\"], \"nested\": {\"x\": [1, 2, 3]}}"
        let text = "[" + Array(repeating: element, count: 45_000).joined(separator: ",") + "]"
        #expect(text.utf8.count > 3_000_000)
        let document = try #require(JSONTreeDocument(text: text))
        #expect(document.root.childCount == 45_000)
        let last = document.root.children[44_999]
        #expect(last.children.map(\.label) == ["id", "name", "tags", "nested"])
        #expect(last.children[3].children[0].path == "$[44999].nested.x")
    }
}
