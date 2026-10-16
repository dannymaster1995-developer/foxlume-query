import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

/// A tiny PNG drawn in memory: an orange sRGB bitmap.
private func pngData(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

extension AppCompletionTests {
    /// The value viewer's modes (Text, JSON, Image, Hex) on values built in memory.
    @Suite("Value viewer")
    @MainActor
    struct ValueViewerAppTests {
        private func viewer(_ value: CellValue, type: String = "", editable: Bool = false, onSave: ((CellValue) -> Void)? = nil) -> ValueEditorController {
            ValueEditorController(column: "c", typeName: type, value: value, editable: editable, onSave: onSave)
        }

        @Test func jsonOpensAsATreeAndFollowsTextEdits() throws {
            var saved: [CellValue] = []
            let controller = viewer(.text("{\"items\": [{\"name\": \"a\"}, {\"name\": \"b\"}], \"ok\": true}"), type: "jsonb", editable: true) { saved.append($0) }
            #expect(controller.modes == [.text, .json, .hex])
            #expect(controller.mode == .json)
            let tree = try #require(controller.jsonTree)
            #expect(tree.outline.numberOfRows == 2, "top-level keys, collapsed")
            #expect(controller.info == "object · {2 keys}")
            tree.expandAll()
            #expect(tree.visibleRowDescriptions() == [
                "items = [2 items] (array)", "  [0] = {1 key} (object)", "    name = a (string)", "  [1] = {1 key} (object)",
                "    name = b (string)", "ok = true (boolean)",
            ])
            tree.selectRow(4)
            #expect(controller.info == "$.items[1].name")
            NSPasteboard.general.clearContents()
            tree.copyPath(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "$.items[1].name")
            tree.copyValue(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "b")

            controller.searchJSON("ok")
            #expect(tree.visibleRowDescriptions() == ["ok = true (boolean)"])
            #expect(controller.info.hasSuffix("1 match"))
            controller.searchJSON("")

            // Edits happen in Text mode; the tree is rebuilt from the edited text.
            controller.show(.text)
            controller.textView.string = "[1, 2, 3]"
            controller.show(.json)
            #expect(tree.visibleRowDescriptions() == ["[0] = 1 (number)", "[1] = 2 (number)", "[2] = 3 (number)"])
            controller.show(.text)
            controller.textView.string = "[1, 2"
            controller.show(.json)
            #expect(tree.document == nil && controller.info == "Not a JSON object or array")
            #expect(saved.isEmpty)
        }

        @Test func textIsLoadedOnlyWhenShown() {
            var saved: [CellValue] = []
            let controller = viewer(.text("{\"a\": 1}"), editable: true) { saved.append($0) }
            #expect(controller.mode == .json)
            #expect(controller.textView.string.isEmpty, "Text mode not built yet")
            controller.show(.text)
            #expect(controller.textView.string == "{\"a\": 1}")
            controller.show(.hex)
            #expect(controller.hexView?.data == Data("{\"a\": 1}".utf8), "Hex of a text is its UTF-8")
        }

        @Test func plainTextAndNull() {
            let text = viewer(.text("hello"), type: "text")
            #expect(text.modes == [.text, .hex] && text.mode == .text)
            #expect(text.textView.string == "hello")
            #expect(text.info == "5 characters")
            let null = viewer(.null, type: "jsonb")
            #expect(null.modes == [.text] && null.mode == .text)
            #expect(null.textView.string.isEmpty)
        }

        @Test func imagesPreviewAndSaveTheirBytes() throws {
            let png = pngData(width: 4, height: 3)
            let controller = viewer(.bytes(png), type: "BLOB")
            #expect(controller.modes == [.text, .image, .hex])
            #expect(controller.mode == .image)
            let preview = try #require(controller.imagePreview)
            #expect(preview.isDecoded)
            #expect(preview.summary == "PNG · 4 × 3 px · \(png.count.groupedText) bytes")
            #expect(controller.suggestedFileName == "c.png")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            try controller.writeBytes(to: url)
            #expect(try Data(contentsOf: url) == png)

            // PostgreSQL sends bytea as `\x` hex text; the viewer decodes it.
            let bytea = viewer(.text("\\x" + png.hexString), type: "bytea")
            #expect(bytea.mode == .image && bytea.binaryData == png)
        }

        @Test func otherBytesOpenInHex() throws {
            let data = Data((0..<40).map { UInt8($0) })
            let controller = viewer(.bytes(data), type: "BLOB")
            #expect(controller.modes == [.text, .hex] && controller.mode == .hex)
            #expect(controller.suggestedFileName == "c.bin")
            let hex = try #require(controller.hexView)
            #expect(hex.lineCount == 3)
            #expect(controller.info == "40 bytes")
            hex.select(14..<18)
            #expect(hex.selectedHex == "0e0f1011")
            #expect(controller.info == "40 bytes · 4 selected at 0xe")
            NSPasteboard.general.clearContents()
            hex.copy(nil)
            #expect(NSPasteboard.general.string(forType: .string) == "0e0f1011")
            hex.selectAll(nil)
            #expect(hex.selection == 0..<40)
        }

        @Test func hexHitTesting() throws {
            let controller = viewer(.bytes(Data(count: 64)), type: "BLOB")
            let hex = try #require(controller.hexView)
            hex.fit(width: 600)
            // Line 1, the second byte of the hex column, and the same byte in the ASCII column.
            let lineHeight = (hex.frame.height - 12) / CGFloat(hex.lineCount)
            let y = 6 + lineHeight * 1.5
            let charWidth = (("0" as NSString).size(withAttributes: [.font: Theme.monospaced(12)])).width
            let hexX = 8 + charWidth * CGFloat(10 + 3) + 1
            let asciiX = 8 + charWidth * CGFloat(10 + HexDump.hexColumnWidth + 1 + 1) + 1
            #expect(hex.byteIndex(at: NSPoint(x: hexX, y: y)) == 17)
            #expect(hex.byteIndex(at: NSPoint(x: asciiX, y: y)) == 17)
            #expect(hex.byteIndex(at: NSPoint(x: 10_000, y: 10_000)) == 63, "clamped to the last byte")
        }

        @Test func largeBlobsSkipTextMode() throws {
            let big = Data(count: 10 * 1024 * 1024)
            let started = Date()
            let controller = viewer(.bytes(big), type: "LONGBLOB")
            #expect(Date().timeIntervalSince(started) < 1)
            #expect(controller.modes == [.hex])
            #expect(controller.hexView?.lineCount == 655_360)
        }

        @Test func gridOpensTheViewerWithTheColumnType() async throws {
            let grid = DataGridView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
            // Closed below and released by Swift; AppKit must not release it a second time.
            window.isReleasedWhenClosed = false
            window.contentView = grid
            window.orderFront(nil)
            defer { window.close() }
            grid.setContent(DataGridContent(columns: [ResultColumn(name: "img", typeName: "bytea")], rows: [[.text("\\x" + pngData(width: 2, height: 2).hexString)]]))
            grid.presentValueEditor(row: 0, column: 0)
            let controller = try #require(ValueEditorController.presented)
            #expect(controller.mode == .image)
            #expect(!controller.editable, "grids that are not editable open the viewer read-only")
            await settle(until: { window.attachedSheet === controller.panel })
            #expect(window.attachedSheet === controller.panel)
            controller.close()
            await settle(until: { window.attachedSheet == nil })
            #expect(window.attachedSheet == nil, "the sheet ended")
        }
    }
}
