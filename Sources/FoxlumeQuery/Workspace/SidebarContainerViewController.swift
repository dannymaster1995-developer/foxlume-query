import AppKit
import FoxlumeQueryCore

/// The sidebar: a "Tables | Saved Queries" switch above either the table list or the saved queries, as TablePro
/// switches its sidebar between Tables and Favorites.
@MainActor
final class SidebarContainerViewController: NSViewController {
    enum Mode: Int {
        case tables
        case savedQueries
    }

    let tables: SidebarViewController
    let savedQueries: SavedQueriesViewController
    private let picker = NSSegmentedControl(labels: ["Tables", "Saved Queries"], trackingMode: .selectOne, target: nil, action: nil)
    private let content = NSView()
    private(set) var mode: Mode = .tables

    init(tables: SidebarViewController, savedQueries: SavedQueriesViewController) {
        self.tables = tables
        self.savedQueries = savedQueries
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        picker.segmentStyle = .automatic
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        picker.selectedSegment = 0
        picker.segmentDistribution = .fillEqually
        picker.target = self
        picker.action = #selector(pickerChanged(_:))
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.setAccessibilityIdentifier("sidebarMode")
        picker.setToolTip("Tables and views", forSegment: 0)
        picker.setToolTip("Saved queries for this connection and all connections", forSegment: 1)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(picker)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: -2),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        addChild(tables)
        addChild(savedQueries)
        view = root
        show(.tables)
    }

    func show(_ mode: Mode) {
        _ = view
        self.mode = mode
        picker.selectedSegment = mode.rawValue
        let shown: NSViewController = mode == .tables ? tables : savedQueries
        let hidden: NSViewController = mode == .tables ? savedQueries : tables
        hidden.view.removeFromSuperview()
        if shown.view.superview !== content {
            content.addSubviewFilling(shown.view)
        }
    }

    @objc private func pickerChanged(_ sender: Any?) {
        show(Mode(rawValue: picker.selectedSegment) ?? .tables)
    }

    /// Focuses the filter of the list in front.
    func focusFilter() {
        switch mode {
        case .tables: tables.focusFilter()
        case .savedQueries: savedQueries.focusFilter()
        }
    }
}
