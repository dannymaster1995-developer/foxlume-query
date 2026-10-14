import AppKit
import FoxlumeQueryCore

/// Column header of the data grid. A click sorts and a Shift-click adds a sort key (TablePro's cycle, see `SortCycle`),
/// a ⌘-click selects the column; drags still reorder and the divider still resizes.
final class GridHeaderView: NSTableHeaderView {
    weak var grid: DataGridView?

    /// AppKit resizes from just before a column's trailing edge to just after it; a press there never sorts.
    private static let resizeZone: ClosedRange<CGFloat> = -3...2
    private static let clickTolerance: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        guard let grid, let tableView else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = column(at: point)
        guard index >= 0, let dataColumn = grid.dataColumnIndex(atTableColumn: index), !isInResizeZone(point) else {
            return super.mouseDown(with: event)
        }
        let order = tableView.tableColumns.map(\.identifier)
        let widths = tableView.tableColumns.map(\.width)
        super.mouseDown(with: event)
        // AppKit ran its own tracking loop: a reorder or resize changed the columns, a drag moved the pointer.
        guard tableView.tableColumns.map(\.identifier) == order, tableView.tableColumns.map(\.width) == widths else { return }
        if let release = NSApp.currentEvent, release.type == .leftMouseUp {
            let up = release.locationInWindow
            let down = event.locationInWindow
            guard abs(up.x - down.x) <= Self.clickTolerance, abs(up.y - down.y) <= Self.clickTolerance else { return }
        }
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if flags == [.command] {
            grid.selectColumn(dataColumn, adding: true)
        } else if flags.isEmpty || flags == [.shift] {
            grid.headerClicked(dataColumn: dataColumn, additive: flags == [.shift])
        }
    }

    private func isInResizeZone(_ point: NSPoint) -> Bool {
        guard let tableView else { return false }
        for index in tableView.tableColumns.indices {
            let edge = headerRect(ofColumn: index).maxX
            if Self.resizeZone.contains(point.x - edge) { return true }
        }
        return false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = column(at: point)
        guard let grid, index >= 0, let dataColumn = grid.dataColumnIndex(atTableColumn: index) else { return nil }
        return grid.headerMenu(forDataColumn: dataColumn)
    }
}

/// Draws the title, a chevron for each sorted column and, from the second key on, its position in the sort.
final class GridHeaderCell: NSTableHeaderCell {
    /// Nil when the column is not sorted.
    var sortAscending: Bool?
    /// 1 for the first key; shown from 2 on, as in TablePro.
    var sortPriority: Int?
    var isColumnSelected = false

    private static let indicatorWidth: CGFloat = 12
    private static let priorityFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // AppKit also paints the empty strip after the last column with that column's cell; draw no marks there.
        guard isDrawingOwnColumn(cellFrame, in: controlView) else {
            return super.drawInterior(withFrame: cellFrame, in: controlView)
        }
        if isColumnSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            cellFrame.fill()
        }
        guard let ascending = sortAscending else {
            return super.drawInterior(withFrame: cellFrame, in: controlView)
        }
        let priority = (sortPriority ?? 1) >= 2 ? sortPriority.map(String.init) : nil
        let priorityAttributes: [NSAttributedString.Key: Any] = [.font: Self.priorityFont, .foregroundColor: NSColor.secondaryLabelColor]
        let priorityWidth = priority.map { ($0 as NSString).size(withAttributes: priorityAttributes).width + 1 } ?? 0
        var titleFrame = cellFrame
        titleFrame.size.width = max(0, cellFrame.width - Self.indicatorWidth - priorityWidth - 4)
        super.drawInterior(withFrame: titleFrame, in: controlView)

        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        guard let image = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: ascending ? "Sorted ascending" : "Sorted descending")?
            .withSymbolConfiguration(configuration)
        else { return }
        let tinted = image.tinted(.secondaryLabelColor)
        let size = tinted.size
        let x = cellFrame.maxX - 6 - size.width
        tinted.draw(in: NSRect(x: x, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let priority {
            let textSize = (priority as NSString).size(withAttributes: priorityAttributes)
            (priority as NSString).draw(at: NSPoint(x: x - priorityWidth, y: cellFrame.midY - textSize.height / 2), withAttributes: priorityAttributes)
        }
    }

    /// The filler is drawn with a copy of the last column's cell, so tell it apart by position: no column lies there.
    private func isDrawingOwnColumn(_ frame: NSRect, in controlView: NSView) -> Bool {
        guard let header = controlView as? NSTableHeaderView else { return true }
        return header.column(at: NSPoint(x: frame.midX, y: frame.midY)) >= 0
    }

    override func accessibilityLabel() -> String? {
        var parts = [stringValue]
        if let sortAscending {
            parts.append(sortAscending ? "sorted ascending" : "sorted descending")
            if let sortPriority, sortPriority >= 2 { parts.append("sort key \(sortPriority)") }
        }
        return parts.joined(separator: ", ")
    }
}

private extension NSImage {
    /// A template symbol drawn in `color`.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
