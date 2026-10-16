import AppKit
import FoxlumeQueryCore

/// Scripted commands for the query editor of the selected tab: the current-statement band, word wrap and
/// Run Statement and Move to Next.
///
///     caret <offset> | caret <line>:<column>   puts the caret there (UTF-16 offset, or 1-based line and column)
///     band                        logs the band's range, its first line and its rect, or "none"
///     statementband on|off        the "Highlight the statement at the cursor" setting
///     wordwrap on|off|toggle      the "Wrap long lines" setting; toggle goes through View › Word Wrap (⌥Z)
///     editorstate                 logs wrapping, the text and visible widths, the horizontal scroller and the ruler's line numbers
///     editorscroll <x>            scrolls the editor sideways to x points
///     runnext                     Query › Run Statement and Move to Next (⌃⌘↩), then logs the result, caret and band
@MainActor
enum EditorAutoTest {
    static let commands: Set<String> = ["caret", "band", "statementband", "wordwrap", "editorstate", "editorscroll", "runnext"]
}

extension AutoTestRunner {
    func performEditor(_ command: String, _ argument: String) async throws {
        switch command {
        case "statementband":
            AppEnvironment.settings.highlightCurrentStatement = argument != "off"
            try await Task.sleep(nanoseconds: 300_000_000)
            return
        case "wordwrap":
            if argument == "toggle" {
                app?.toggleWordWrap(nil)
            } else {
                AppEnvironment.settings.editorWordWrap = argument != "off"
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            record("  word wrap: \(AppEnvironment.settings.editorWordWrap ? "on" : "off")")
            return
        default:
            break
        }
        guard let query = workspace?.tabs.selectedTab?.content as? QueryTabViewController else {
            throw DatabaseError.unsupported("\(command) needs a query tab")
        }
        switch command {
        case "caret":
            guard let location = Self.offset(argument, in: query.sql) else { throw DatabaseError.unsupported("caret <offset> | <line>:<column>") }
            query.placeCaret(at: location)
            try await Task.sleep(nanoseconds: 300_000_000)
            recordBand(of: query)
        case "band":
            recordBand(of: query)
        case "editorstate":
            let editor = query.editorForTesting
            editor.layoutSubtreeIfNeeded()
            let labels = (editor.scrollView.verticalRulerView as? LineNumberRulerView)?.visibleLineLabels().map(\.number) ?? []
            record("  wrap: \(query.wrapsLines ? "on" : "off"); text width \(Int(editor.textView.frame.width)), visible \(Int(editor.visibleTextWidth)), x \(Int(editor.scrollView.documentVisibleRect.minX)); horizontal scroller: \(editor.scrollView.hasHorizontalScroller ? "yes" : "no")")
            record("  ruler: " + (labels.isEmpty ? "-" : "\(labels.first!)…\(labels.last!) (\(labels.count))"))
        case "editorscroll":
            let editor = query.editorForTesting
            let clip = editor.scrollView.contentView
            clip.scroll(to: NSPoint(x: CGFloat(Double(argument) ?? 0), y: clip.bounds.minY))
            editor.scrollView.reflectScrolledClipView(clip)
            try await Task.sleep(nanoseconds: 300_000_000)
        case "runnext":
            query.runStatementAndMoveToNext(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitFor(seconds: 30) { !query.isRunning }
            try await Task.sleep(nanoseconds: 300_000_000)
            let first = query.currentResult?.rows.first?.first.map { "\($0)" } ?? "-"
            record("  result: \(query.resultStatus); first cell \(first)")
            recordBand(of: query)
        default:
            break
        }
    }

    private func recordBand(of query: QueryTabViewController) {
        guard let band = query.statementBandRange else {
            return record("  caret \(query.caretLocation); band: none")
        }
        let text = (query.sql as NSString).substring(with: band)
        let firstLine = text.components(separatedBy: "\n").first ?? ""
        let rect = query.statementBandRect.map { " rect y \(Int($0.minY)) h \(Int($0.height))" } ?? ""
        record("  caret \(query.caretLocation); band \(band.location)+\(band.length): \(firstLine)\(rect)")
    }

    /// A UTF-16 offset, or `line:column` counted from 1.
    static func offset(_ argument: String, in text: String) -> Int? {
        let parts = argument.split(separator: ":").compactMap { Int($0) }
        if parts.count == 1, !argument.contains(":") { return parts[0] }
        guard parts.count == 2, parts[0] >= 1, parts[1] >= 1 else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard parts[0] <= lines.count else { return nil }
        let before = lines.prefix(parts[0] - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return before + min(parts[1] - 1, (lines[parts[0] - 1] as NSString).length)
    }
}
