import AppKit
import FoxlumeQueryCore

/// A folder or query row with identity that survives `reloadData`.
final class SavedQueryNode: NSObject {
    let folder: SavedQueryFolder?
    let query: SavedQuery?
    var children: [SavedQueryNode] = []

    init(folder: SavedQueryFolder) {
        self.folder = folder
        self.query = nil
    }

    init(query: SavedQuery) {
        self.folder = nil
        self.query = query
    }

    var isFolder: Bool { folder != nil }
    var id: UUID { folder?.id ?? query!.id }
    var name: String { folder?.name ?? query!.name }
    var connectionID: UUID? { folder?.connectionID ?? query?.connectionID }

    /// Folders first, then queries. A folder whose parent is not shown (or that sits in a loop) is a root.
    static func tree(_ library: SavedQueryLibrary, filter: String) -> [SavedQueryNode] {
        let folderIDs = Set(library.folders.map(\.id))
        var placed: Set<UUID> = []
        func build(_ parent: UUID?) -> [SavedQueryNode] {
            var nodes: [SavedQueryNode] = []
            for folder in library.folders where folder.parentID == parent && placed.insert(folder.id).inserted {
                let node = SavedQueryNode(folder: folder)
                node.children = build(folder.id)
                nodes.append(node)
            }
            nodes += library.queries(in: parent).map(SavedQueryNode.init(query:))
            return nodes
        }
        var roots = build(nil)
        // Orphans: a missing parent, or a loop that never reaches the top.
        for folder in library.folders where !placed.contains(folder.id) && (folder.parentID.map { !folderIDs.contains($0) } ?? false) {
            placed.insert(folder.id)
            let node = SavedQueryNode(folder: folder)
            node.children = build(folder.id)
            roots.insert(node, at: roots.firstIndex { !$0.isFolder } ?? roots.count)
        }
        for folder in library.folders where !placed.contains(folder.id) {
            placed.insert(folder.id)
            let node = SavedQueryNode(folder: folder)
            node.children = build(folder.id)
            roots.insert(node, at: roots.firstIndex { !$0.isFolder } ?? roots.count)
        }
        guard !filter.isEmpty else { return roots }
        return roots.compactMap { $0.filtered(filter.lowercased()) }
    }

    /// Itself when it matches, with all its contents for a folder; otherwise only the matching descendants.
    private func filtered(_ needle: String) -> SavedQueryNode? {
        if let query {
            let hit = query.name.lowercased().contains(needle) || (query.keyword?.lowercased().contains(needle) ?? false) || query.sql.lowercased().contains(needle)
            return hit ? self : nil
        }
        if name.lowercased().contains(needle) { return self }
        let kept = children.compactMap { $0.filtered(needle) }
        guard !kept.isEmpty, let folder else { return nil }
        let copy = SavedQueryNode(folder: folder)
        copy.children = kept
        return copy
    }

    static func queryCount(_ nodes: [SavedQueryNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? queryCount($1.children) : 1) }
    }

    static func find(_ id: UUID, in nodes: [SavedQueryNode]) -> SavedQueryNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = find(id, in: node.children) { return found }
        }
        return nil
    }

    static func find(named name: String, in nodes: [SavedQueryNode]) -> SavedQueryNode? {
        for node in nodes {
            if node.name == name { return node }
            if let found = find(named: name, in: node.children) { return found }
        }
        return nil
    }

    /// Every folder depth-first, with its depth (0 for top-level folders), for folder pickers.
    static func foldersInOrder(_ library: SavedQueryLibrary) -> [(folder: SavedQueryFolder, depth: Int)] {
        var result: [(SavedQueryFolder, Int)] = []
        var seen: Set<UUID> = []
        func walk(_ nodes: [SavedQueryNode], depth: Int) {
            for node in nodes {
                guard let folder = node.folder, seen.insert(folder.id).inserted else { continue }
                result.append((folder, depth))
                walk(node.children, depth: depth + 1)
            }
        }
        walk(tree(library, filter: ""), depth: 0)
        return result
    }
}

/// Star or folder icon, the name, the keyword in a dimmed monospaced font (a narrow sidebar cuts the keyword before
/// the name), and a globe for items shared with every connection. Plain labels keep the sidebar's vibrant text colors.
final class SavedQueryCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let keyword = NSTextField(labelWithString: "")
    private let globe = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        for label in [name, keyword] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        name.font = .systemFont(ofSize: 12)
        name.setContentCompressionResistancePriority(.defaultLow + 10, for: .horizontal)
        keyword.font = Theme.monospaced(10.5)
        keyword.textColor = .tertiaryLabelColor
        keyword.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
        keyword.setContentHuggingPriority(.required, for: .horizontal)
        globe.translatesAutoresizingMaskIntoConstraints = false
        globe.image = Theme.image("globe", "Available in all connections", size: 10)
        globe.contentTintColor = .tertiaryLabelColor
        globe.toolTip = "Available in all connections"
        globe.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A stack drops the keyword and globe from the layout when they are hidden, so the name gets their room.
        let line = NSStackView(views: [name, keyword, globe])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = 6
        line.detachesHiddenViews = true
        line.translatesAutoresizingMaskIntoConstraints = false
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(line)
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            line.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A keyword that would show only a sliver is left out; the tooltip still has it.
    override func layout() {
        super.layout()
        let fits = !keyword.stringValue.isEmpty && keyword.frame.width + 0.5 >= keyword.intrinsicContentSize.width
        keyword.alphaValue = fits ? 1 : 0
    }

    func configure(_ node: SavedQueryNode) {
        name.isEditable = false
        name.drawsBackground = false
        name.stringValue = node.name
        globe.isHidden = node.connectionID != nil
        keyword.stringValue = node.query?.keyword ?? ""
        keyword.isHidden = keyword.stringValue.isEmpty
        if let query = node.query {
            icon.image = Theme.image("star.fill", "Saved query")
            icon.contentTintColor = .systemYellow
            var tip = query.name
            if let word = query.keyword, !word.isEmpty { tip += "\nKeyword: \(word)" }
            let lines = query.sql.split(whereSeparator: \.isNewline).prefix(8).joined(separator: "\n")
            tip += "\n\n" + (lines.count > 600 ? String(lines.prefix(600)) + "…" : lines)
            toolTip = tip
        } else {
            icon.image = Theme.image("folder", "Folder")
            icon.contentTintColor = .secondaryLabelColor
            toolTip = node.name
        }
    }
}
