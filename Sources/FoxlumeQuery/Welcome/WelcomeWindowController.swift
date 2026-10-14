import AppKit
import FoxlumeQueryCore
import SwiftUI

@MainActor
final class WelcomeModel: ObservableObject {
    @Published var connections: [ConnectionConfig] = []
    @Published var search = ""
    @Published var selection: UUID?
    @Published var connectingID: UUID?

    var onConnect: ((ConnectionConfig) -> Void)?
    var onNew: (() -> Void)?
    var onEdit: ((ConnectionConfig) -> Void)?
    var onOpenFile: (() -> Void)?

    init() {
        reload()
        NotificationCenter.default.addObserver(forName: ConnectionStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        connections = AppEnvironment.connections.all()
    }

    var groups: [(String, [ConnectionConfig])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = connections.filter {
            query.isEmpty || $0.displayName.lowercased().contains(query) || $0.subtitle.lowercased().contains(query) || $0.kind.displayName.lowercased().contains(query)
        }
        let grouped = Dictionary(grouping: filtered) { $0.group.trimmingCharacters(in: .whitespaces) }
        return grouped.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return true }
            if rhs.isEmpty { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.map { key in
            (key, (grouped[key] ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        }
    }

    func duplicate(_ config: ConnectionConfig) {
        var copy = config
        copy.id = UUID()
        copy.name = config.displayName + " Copy"
        copy.lastUsedAt = nil
        try? AppEnvironment.connections.save(copy)
        if let password = AppEnvironment.credentials.password(for: config.id) {
            try? AppEnvironment.credentials.setPassword(password, for: copy.id)
        }
        if let secret = AppEnvironment.credentials.sshSecret(for: config.id) {
            try? AppEnvironment.credentials.setSSHSecret(secret, for: copy.id)
        }
        if let secret = AppEnvironment.credentials.tlsSecret(for: config.id) {
            try? AppEnvironment.credentials.setTLSSecret(secret, for: copy.id)
        }
        selection = copy.id
    }

    func delete(_ config: ConnectionConfig) {
        try? AppEnvironment.connections.delete(id: config.id)
        AppEnvironment.credentials.deletePassword(for: config.id)
        AppEnvironment.credentials.deleteSSHSecret(for: config.id)
        AppEnvironment.credentials.deleteTLSSecret(for: config.id)
        // Queries saved for this connection only go with it, as in TablePro; shared ones stay.
        try? AppEnvironment.savedQueries.removeConnection(config.id)
        AppEnvironment.openQuicklyFrecency.removeConnection(config.id)
    }

    func connection(_ id: UUID?) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        HStack(spacing: 0) {
            sidePanel
                .frame(width: 250)
            Divider()
            connectionList
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private var sidePanel: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 30)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Foxlume Query")
                .font(.system(size: 26, weight: .bold))
            Text("Version \(AppEnvironment.appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("PostgreSQL · MySQL\nBeta: MariaDB · SQLite · DuckDB\nMongoDB · Redis")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            VStack(spacing: 8) {
                Button {
                    model.onNew?()
                } label: {
                    Label("New Connection…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("newConnection")
                Button {
                    model.onOpenFile?()
                } label: {
                    Label("Open Database File…", systemImage: "doc")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
        .background(.background.opacity(0.4))
    }

    private var connectionList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search connections", text: $model.search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("connectionSearch")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            .padding(12)

            if model.connections.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("No connections yet")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Create one to connect to PostgreSQL, MySQL, MariaDB, SQLite, DuckDB, MongoDB or Redis.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Button("New Connection…") { model.onNew?() }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.groups, id: \.0) { group, items in
                        Section(group.isEmpty ? "Connections" : group) {
                            ForEach(items) { config in
                                ConnectionRow(config: config, connecting: model.connectingID == config.id)
                                    .tag(config.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let config = model.connection(ids.first) {
                        Button("Connect") { model.onConnect?(config) }
                        Button("Edit…") { model.onEdit?(config) }
                        Button("Duplicate") { model.duplicate(config) }
                        Divider()
                        Button("Delete", role: .destructive) { confirmDelete(config) }
                    }
                } primaryAction: { ids in
                    if let config = model.connection(ids.first) { model.onConnect?(config) }
                }
                .accessibilityIdentifier("connectionList")
            }

            Divider()
            HStack {
                Button {
                    model.onNew?()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Connection")
                Button {
                    if let config = model.connection(model.selection) { confirmDelete(config) }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(model.selection == nil)
                .help("Delete Connection")
                Button {
                    if let config = model.connection(model.selection) { model.onEdit?(config) }
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(model.selection == nil)
                .help("Edit Connection")
                Spacer()
                Button("Connect") {
                    if let config = model.connection(model.selection) { model.onConnect?(config) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selection == nil || model.connectingID != nil)
            }
            .padding(10)
        }
    }

    private func confirmDelete(_ config: ConnectionConfig) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(config.displayName)”?"
        alert.informativeText = "The saved connection and its password are removed. Your database is not touched."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.delete(config)
        }
    }
}

private struct ConnectionRow: View {
    let config: ConnectionConfig
    let connecting: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill((Theme.color(for: config.color).map { Color(nsColor: $0) } ?? Color.accentColor).opacity(0.18))
                Image(systemName: Theme.symbol(for: config.kind))
                    .foregroundStyle(Theme.color(for: config.color).map { Color(nsColor: $0) } ?? Color.accentColor)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.displayName).font(.body.weight(.medium))
                    if config.environment != .none {
                        Text(config.environment.displayName.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(Color(nsColor: Theme.color(for: config.environment)))
                            .background(Capsule().fill(Color(nsColor: Theme.color(for: config.environment)).opacity(0.15)))
                    }
                    if config.kind.isBeta {
                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(Color.orange)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .help("\(config.kind.displayName) support is in beta")
                    }
                    if config.safeModeLevel != .silent {
                        Image(systemName: config.safeModeLevel.symbolName).font(.caption2).foregroundStyle(.secondary)
                            .help("Safe Mode: \(config.safeModeLevel.title)")
                    }
                }
                Text("\(config.kind.displayName) · \(config.subtitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if connecting {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("connection-\(config.displayName)")
    }
}

@MainActor
final class WelcomeWindowController: NSWindowController {
    let model = WelcomeModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Foxlume Query"
        window.isRestorable = false
        window.isMovableByWindowBackground = true
        window.setAccessibilityIdentifier("welcomeWindow")
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: WelcomeView(model: model))
        window.setContentSize(NSSize(width: 780, height: 480))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
