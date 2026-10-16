import AppKit
import FoxlumeQueryCore

/// Scripted commands for the value viewer (JSON tree, image preview, hex dump); see the list in AutoTestRunner+Grid.
extension AutoTestRunner {
    func performValueViewer(_ command: String, _ argument: String, grid: DataGridView, column: (String) throws -> Int) async throws {
        let words = argument.split(separator: " ").map(String.init)
        if command == "viewvalue" {
            guard words.count == 2, let row = Int(words[0]) else { throw DatabaseError.unsupported("viewvalue <row> <column>") }
            let index = try column(words[1])
            let started = Date()
            grid.presentValueEditor(row: row, column: index)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            guard let viewer = ValueEditorController.presented, viewer.panel.isVisible || viewer.panel.sheetParent != nil else {
                throw DatabaseError.unsupported("The value viewer did not open")
            }
            record("  opened in \(elapsed) ms")
            try await Task.sleep(nanoseconds: 400_000_000)
            return logViewer(viewer)
        }
        guard let viewer = ValueEditorController.presented, viewer.panel.sheetParent != nil else {
            throw DatabaseError.unsupported("No value viewer is open")
        }
        switch command {
        case "viewer":
            logViewer(viewer)
        case "viewermode":
            guard let mode = ValueViewMode(rawValue: argument), viewer.modes.contains(mode) else {
                throw DatabaseError.unsupported("viewermode \(viewer.modes.map(\.rawValue).joined(separator: "|"))")
            }
            viewer.show(mode)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "viewertype":
            viewer.show(.text)
            let text = Self.queryText(argument)
            let textView = viewer.textView
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: all, replacementString: text) {
                textView.string = text
                textView.didChangeText()
            } else {
                record("  ! the text is read-only")
            }
        case "jsonexpand", "jsoncollapse", "jsonsearch", "jsonselect", "jsoncopy":
            guard viewer.mode == .json, let tree = viewer.jsonTree else { throw DatabaseError.unsupported("\(command) needs JSON mode") }
            switch command {
            case "jsonexpand": tree.expandAll()
            case "jsoncollapse": tree.collapseAll()
            case "jsonsearch": viewer.searchJSON(argument == "-" ? "" : argument)
            case "jsonselect":
                guard let row = Int(argument), row < tree.outline.numberOfRows else { throw DatabaseError.unsupported("jsonselect <row>") }
                tree.selectRow(row)
            default:
                NSPasteboard.general.clearContents()
                if argument == "path" { tree.copyPath(nil) } else { tree.copyValue(nil) }
                record("  copied: " + (NSPasteboard.general.string(forType: .string) ?? "").replacingOccurrences(of: "\n", with: " ⏎ "))
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        case "hexselect", "hexcopy":
            guard viewer.mode == .hex, let hex = viewer.hexView else { throw DatabaseError.unsupported("\(command) needs Hex mode") }
            if command == "hexselect" {
                guard words.count == 2, let start = Int(words[0]), let length = Int(words[1]) else { throw DatabaseError.unsupported("hexselect <start> <length>") }
                hex.select(start..<(start + length))
                hex.scrollToSelection()
            } else {
                NSPasteboard.general.clearContents()
                hex.copy(nil)
                record("  copied: " + (NSPasteboard.general.string(forType: .string) ?? ""))
            }
        case "viewersave":
            guard let path = words.first else { throw DatabaseError.unsupported("viewersave <path> [<compare>]") }
            let url = URL(fileURLWithPath: path)
            try viewer.writeBytes(to: url)
            let written = try Data(contentsOf: url)
            var line = "  saved \(written.count) bytes as \(url.lastPathComponent) (suggested \(viewer.suggestedFileName))"
            if let compare = words.dropFirst().first {
                line += (try? Data(contentsOf: URL(fileURLWithPath: compare))) == written ? ", identical to \(URL(fileURLWithPath: compare).lastPathComponent)" : ", DIFFERENT from \(compare)"
            }
            // The check is all that is needed; leave no file behind.
            try? FileManager.default.removeItem(at: url)
            record(line)
        case "viewersnapshot":
            // The sheet alone, drawn offscreen: a window capture of a sheet returns its parent window.
            let url = snapshotDirectory.appendingPathComponent(argument.isEmpty ? "viewer.png" : argument)
            guard let frameView = viewer.panel.contentView?.superview else { throw DatabaseError.unsupported("No viewer to capture") }
            try write(view: frameView, to: url)
        case "viewerclose":
            viewer.close()
            try await Task.sleep(nanoseconds: 300_000_000)
        default:
            throw DatabaseError.unsupported("Unknown command \(command)")
        }
    }

    private func logViewer(_ viewer: ValueEditorController) {
        record("  modes: " + viewer.modes.map { $0 == viewer.mode ? "[\($0.title)]" : $0.title }.joined(separator: " "))
        record("  info: " + viewer.info + (viewer.editable ? "" : " (read-only)"))
        switch viewer.mode {
        case .text:
            let text = viewer.currentText
            record("  text: " + (text.count > 120 ? String(text.prefix(120)) + "…" : text).replacingOccurrences(of: "\n", with: " ⏎ "))
        case .json:
            for line in viewer.jsonTree?.visibleRowDescriptions(limit: 30) ?? [] {
                record("    " + line)
            }
        case .image:
            if let preview = viewer.imagePreview { record("  image: \(preview.summary), decoded: \(preview.isDecoded)") }
        case .hex:
            guard let hex = viewer.hexView else { return }
            record("  lines: \(hex.lineCount)")
            for index in 0..<min(hex.lineCount, 3) {
                let line = HexDump.line(index, of: hex.data, offsetDigits: HexDump.offsetDigits(byteCount: hex.data.count))
                record("    \(line.offset)  \(line.hex)  |\(line.ascii)|")
            }
        }
    }
}
