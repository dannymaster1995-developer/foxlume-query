import CoreGraphics
import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct TabStripLayoutTests {
    /// Tabs of 120 to 240 pt, 4 pt apart, and a 40 pt "+N" button.
    private let metrics = TabStripLayout.Metrics()

    @Test func everyTabShowsWhenTheyFitAtTheMinimumWidth() {
        // 5 × 120 + 4 × 4 = 616.
        let fit = TabStripLayout.fit(tabCount: 5, width: 616, metrics: metrics)
        #expect(fit == TabStripLayout(visibleCount: 5, tabWidth: 120, hiddenCount: 0))
        #expect(!fit.showsOverflow)
    }

    @Test func tabsGrowUpToTheMaximumWidth() {
        #expect(TabStripLayout.fit(tabCount: 2, width: 1000, metrics: metrics).tabWidth == 240)
        #expect(TabStripLayout.fit(tabCount: 3, width: 500, metrics: metrics).tabWidth == 164)
        #expect(TabStripLayout.fit(tabCount: 1, width: 100, metrics: metrics) == TabStripLayout(visibleCount: 1, tabWidth: 100, hiddenCount: 0))
    }

    @Test func overflowLeavesRoomForThePlusNButton() {
        // 615 pt is one short of five tabs; the "+N" button takes 44, leaving 571 for four tabs (4 × 124 = 496 ≤ 575).
        let fit = TabStripLayout.fit(tabCount: 5, width: 615, metrics: metrics)
        #expect(fit.visibleCount == 4)
        #expect(fit.hiddenCount == 1)
        #expect(fit.tabWidth == 139) // (571 - 12) / 4, rounded down
        // Twenty tabs in the room a 1200 pt window leaves: (900 - 44 + 4) / 124 = 6.
        let many = TabStripLayout.fit(tabCount: 20, width: 900, metrics: metrics)
        #expect(many.visibleCount == 6 && many.hiddenCount == 14)
        #expect(CGFloat(many.visibleCount) * (many.tabWidth + 4) + 44 <= 900 + 4)
    }

    @Test func oneTabAlwaysShowsHoweverNarrow() {
        let fit = TabStripLayout.fit(tabCount: 8, width: 60, metrics: metrics)
        #expect(fit.visibleCount == 1 && fit.hiddenCount == 7)
        #expect(fit.tabWidth == 16)
        #expect(TabStripLayout.fit(tabCount: 0, width: 600, metrics: metrics).visibleCount == 0)
        #expect(TabStripLayout.fit(tabCount: 3, width: -10, metrics: metrics).visibleCount == 1)
    }

    @Test func visibleTabsPreferTheSelectedThenTheRecentAndKeepTabOrder() {
        let order = ["a", "b", "c", "d", "e", "f"]
        // Room for three: the selected "e", then "b" and "f" by recency; shown in tab order.
        #expect(TabStripLayout.visibleTabs(order, recency: ["b", "f", "a"], selected: "e", limit: 3) == ["b", "e", "f"])
        // The selected tab is usually first in the recency list too.
        #expect(TabStripLayout.visibleTabs(order, recency: ["e", "b", "f", "a"], selected: "e", limit: 3) == ["b", "e", "f"])
        // Tabs never selected rank after the used ones, in tab order.
        #expect(TabStripLayout.visibleTabs(order, recency: ["d"], selected: "d", limit: 3) == ["a", "b", "d"])
        // Unknown and closed IDs in the recency list are skipped.
        #expect(TabStripLayout.visibleTabs(order, recency: ["x", "c"], selected: nil, limit: 2) == ["a", "c"])
        #expect(TabStripLayout.visibleTabs(order, recency: [], selected: nil, limit: 6) == order)
        #expect(TabStripLayout.visibleTabs(order, recency: [], selected: "a", limit: 0) == [])
    }

    @Test func selectingAHiddenTabReplacesTheLeastRecentlyUsedVisibleOne() {
        let order = Array(1...8)
        var recency = TabRecency<Int>()
        for id in order { recency.use(id) } // opened one after another; 8 is the newest
        #expect(recency.ids == [8, 7, 6, 5, 4, 3, 2, 1])
        var visible = TabStripLayout.visibleTabs(order, recency: recency.ids, selected: 8, limit: 4)
        #expect(visible == [5, 6, 7, 8])

        // Clicking a shown tab keeps the same tabs in view.
        recency.use(6)
        #expect(TabStripLayout.visibleTabs(order, recency: recency.ids, selected: 6, limit: 4) == visible)

        // Picking hidden tab 2 brings it in and drops 5, the least recently used of the shown ones.
        recency.use(2)
        visible = TabStripLayout.visibleTabs(order, recency: recency.ids, selected: 2, limit: 4)
        #expect(visible == [2, 6, 7, 8])

        // A closed tab leaves the recency list; the next most recent one comes back into view.
        recency.remove(7)
        #expect(recency.ids == [2, 6, 8, 5, 4, 3, 1])
        #expect(TabStripLayout.visibleTabs([1, 2, 3, 4, 5, 6, 8], recency: recency.ids, selected: 2, limit: 4) == [2, 5, 6, 8])
    }
}
