import CoreGraphics
import Foundation

/// How the editor tab strip fits its tabs into the width it has: as many as fit between the minimum and maximum
/// tab width, the rest behind a "+N" button. The strip never asks for more width than one tab and its buttons.
public struct TabStripLayout: Equatable, Sendable {
    public struct Metrics: Equatable, Sendable {
        public var minimumTabWidth: CGFloat
        public var maximumTabWidth: CGFloat
        public var spacing: CGFloat
        /// Room for the "+N" button, without the spacing before it.
        public var overflowButtonWidth: CGFloat

        public init(minimumTabWidth: CGFloat = 120, maximumTabWidth: CGFloat = 240, spacing: CGFloat = 4, overflowButtonWidth: CGFloat = 40) {
            self.minimumTabWidth = minimumTabWidth
            self.maximumTabWidth = maximumTabWidth
            self.spacing = spacing
            self.overflowButtonWidth = overflowButtonWidth
        }
    }

    /// Tabs shown in the strip; the others are hidden behind the "+N" button.
    public var visibleCount: Int
    /// Width of each shown tab.
    public var tabWidth: CGFloat
    public var hiddenCount: Int

    public var showsOverflow: Bool { hiddenCount > 0 }

    public init(visibleCount: Int, tabWidth: CGFloat, hiddenCount: Int) {
        self.visibleCount = visibleCount
        self.tabWidth = tabWidth
        self.hiddenCount = hiddenCount
    }

    /// Fits `tabCount` tabs into `width`, the room between the strip's leading inset and its "+" button.
    /// At least one tab always shows, narrower than the minimum when even one does not fit.
    public static func fit(tabCount: Int, width: CGFloat, metrics: Metrics = Metrics()) -> TabStripLayout {
        guard tabCount > 0 else { return TabStripLayout(visibleCount: 0, tabWidth: 0, hiddenCount: 0) }
        let width = max(0, width)
        let step = metrics.minimumTabWidth + metrics.spacing
        let visible: Int
        if CGFloat(tabCount) * step - metrics.spacing <= width {
            visible = tabCount
        } else {
            let room = width - metrics.overflowButtonWidth - metrics.spacing
            let fitting = Int(((room + metrics.spacing) / step).rounded(.down))
            visible = max(1, min(tabCount - 1, fitting))
        }
        let hidden = tabCount - visible
        let room = hidden > 0 ? width - metrics.overflowButtonWidth - metrics.spacing : width
        let share = (room - CGFloat(visible - 1) * metrics.spacing) / CGFloat(visible)
        let tabWidth = max(0, min(metrics.maximumTabWidth, share.rounded(.down)))
        return TabStripLayout(visibleCount: visible, tabWidth: tabWidth, hiddenCount: hidden)
    }

    /// Which tabs show when only `limit` fit: the selected tab, then the most recently used ones. Tabs missing from
    /// `recency` (most recent first) rank after it, in tab order. The result keeps the tabs' own order.
    public static func visibleTabs<ID: Hashable>(_ order: [ID], recency: [ID], selected: ID?, limit: Int) -> [ID] {
        guard limit < order.count else { return order }
        guard limit > 0 else { return [] }
        let present = Set(order)
        var ranked: [ID] = []
        var seen = Set<ID>()
        func add(_ id: ID) {
            guard present.contains(id), !seen.contains(id) else { return }
            seen.insert(id)
            ranked.append(id)
        }
        if let selected { add(selected) }
        recency.forEach(add)
        order.forEach(add)
        let chosen = Set(ranked.prefix(limit))
        return order.filter { chosen.contains($0) }
    }
}

/// Most recently used order of a window's tabs, most recent first.
public struct TabRecency<ID: Hashable>: Equatable {
    public private(set) var ids: [ID] = []

    public init(_ ids: [ID] = []) {
        self.ids = ids
    }

    /// Moves `id` to the front.
    public mutating func use(_ id: ID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
    }

    public mutating func remove(_ id: ID) {
        ids.removeAll { $0 == id }
    }
}
