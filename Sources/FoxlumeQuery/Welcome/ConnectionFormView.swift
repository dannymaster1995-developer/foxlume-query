import AppKit
import FoxlumeQueryCore
import SwiftUI

@MainActor
final class ConnectionFormModel: ObservableObject {
    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    @Published var config: ConnectionConfig
    @Published var password: String
    @Published var sshSecret: String
    /// Client key passphrase or PKCS#12 password.
    @Published var tlsSecret: String
    /// The client certificate comes as a PKCS#12 file rather than PEM certificate and key files.
    @Published var usesPKCS12: Bool
    @Published var testState: TestState = .idle
    /// Set by the scripted UI checks to scroll the form to a section ("tls").
    @Published var scrollTarget: String?
    let isNew: Bool
    /// Last file check, so the form does not reread the files on every redraw.
    var tlsCheckCache: (key: String, result: TLSFileCheck)?

    var onSave: ((ConnectionConfig, _ password: String, _ sshSecret: String, _ tlsSecret: String, _ connect: Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(config: ConnectionConfig?, password: String, sshSecret: String = "", tlsSecret: String = "") {
        self.config = config ?? ConnectionConfig(kind: .postgresql)
        self.password = password
        self.sshSecret = sshSecret
        self.tlsSecret = tlsSecret
        self.usesPKCS12 = !(config?.certificates.pkcs12Path.isEmpty ?? true)
        self.isNew = config == nil
    }

    var redisMode: String { config.option(.redisMode) ?? "" }

    /// Redis keeps the database index in `config.database`.
    var redisDatabaseIndex: Int {
        get { Int(config.database) ?? 0 }
        set { config.database = String(newValue) }
    }

    /// Non-optional view of the tunnel settings for form bindings.
    var ssh: SSHConfig {
        get { config.ssh ?? SSHConfig(user: NSUserName()) }
        set { config.ssh = newValue }
    }

    func changeKind(to kind: DatabaseKind) {
        let previous = config.kind
        guard previous != kind else { return }
        if config.port == previous.defaultPort || config.port == 0 { config.port = kind.defaultPort }
        if config.user == previous.defaultUser || config.user.isEmpty { config.user = kind.defaultUser }
        config.kind = kind
        if kind == .redis, Int(config.database) == nil { config.database = "" }
        // TablePro offers no "Preferred" for Redis; plaintext servers are the common case.
        if kind == .redis, config.sslMode == .prefer { config.sslMode = .disable }
        testState = .idle
    }

    var validationMessage: String? {
        if config.kind.isFileBased {
            return config.filePath.trimmingCharacters(in: .whitespaces).isEmpty ? "Choose a database file." : nil
        }
        if config.kind == .mongodb, config.option(.mongoConnectionString) != nil { return nil }
        if config.kind == .redis, ["sentinel", "cluster"].contains(redisMode), config.option(.redisNodes) == nil, config.host.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the \(redisMode) nodes."
        }
        if config.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a host." }
        if !(1...65535).contains(config.port) { return "Enter a port between 1 and 65535." }
        if config.usesSSH {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the SSH host." }
            if ssh.authMethod == .keyFile, ssh.keyPath.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose an SSH private key." }
        }
        if let message = tlsValidationMessage { return message }
        return nil
    }

    func test() {
        testState = .testing
        let parameters = ConnectionParameters(config: config, password: password, sshSecret: sshSecret, tlsSecret: tlsSecret.isEmpty ? nil : tlsSecret)
        Task {
            let session = DatabaseSession(parameters: parameters)
            let started = Date()
            do {
                try await session.connect()
                let elapsed = Date().timeIntervalSince(started)
                var security = ""
                if let version = session.tlsProtocolVersion {
                    security = " over \(version)" + (config.sslMode.wantsTLS && config.certificates.hasClientCertificate ? " with a client certificate" : "")
                }
                testState = .success("Connected to \(config.kind.displayName) \(session.serverVersion) in \(elapsed.durationText)\(security)")
            } catch {
                testState = .failure(error.localizedDescription)
            }
            await session.close()
        }
    }

    func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "Choose an SSH private key"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ssh.keyPath = url.path
    }

    func chooseFile(create: Bool) {
        let panel: NSSavePanel
        if create {
            panel = NSSavePanel()
            panel.nameFieldStringValue = config.kind == .duckdb ? "database.duckdb" : "database.sqlite"
        } else {
            let open = NSOpenPanel()
            open.canChooseFiles = true
            open.canChooseDirectories = false
            open.allowsMultipleSelection = false
            panel = open
        }
        let engine = config.kind.displayName
        panel.message = create ? "Create a new \(engine) database" : (config.kind == .duckdb ? "Choose a DuckDB database or a Parquet, CSV or JSON file" : "Choose a \(engine) database")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.filePath = url.path
        if config.name.isEmpty { config.name = url.deletingPathExtension().lastPathComponent }
    }
}

struct ConnectionFormView: View {
    @ObservedObject var model: ConnectionFormModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: Binding(get: { model.config.kind }, set: { model.changeKind(to: $0) })) {
                        ForEach(DatabaseKind.allCases) { kind in
                            Label(kind.isBeta ? "\(kind.displayName) (Beta)" : kind.displayName, systemImage: Theme.symbol(for: kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    betaNote
                    .accessibilityIdentifier("connectionKind")
                    TextField("Name", text: $model.config.name, prompt: Text(model.config.displayName.isEmpty ? "My Database" : model.config.displayName))
                        .accessibilityIdentifier("connectionName")
                }

                if model.config.kind.isFileBased {
                    Section("Database File") {
                        HStack {
                            TextField("File", text: $model.config.filePath, prompt: Text(model.config.kind == .duckdb ? "/path/to/database.duckdb, .parquet, .csv" : "/path/to/database.sqlite"))
                                .accessibilityIdentifier("connectionFile")
                            Button("Choose…") { model.chooseFile(create: false) }
                            Button("New…") { model.chooseFile(create: true) }
                        }
                    }
                } else {
                    Section("Server") {
                        HStack {
                            TextField("Host", text: $model.config.host, prompt: Text("127.0.0.1"))
                                .accessibilityIdentifier("connectionHost")
                            TextField("Port", value: $model.config.port, format: .number.grouping(.never))
                                .frame(width: 110)
                                .accessibilityIdentifier("connectionPort")
                        }
                        TextField(model.config.kind == .redis ? "Username" : "User", text: $model.config.user, prompt: Text(model.config.kind == .redis ? "Optional ACL user" : (model.config.kind == .mongodb ? "Optional" : "")))
                            .accessibilityIdentifier("connectionUser")
                        SecureField("Password", text: $model.password)
                            .accessibilityIdentifier("connectionPassword")
                        if model.config.kind == .redis {
                            if model.redisMode != "cluster" {
                                Stepper("Database Index: \(model.redisDatabaseIndex)", value: Binding(get: { model.redisDatabaseIndex }, set: { model.redisDatabaseIndex = $0 }), in: 0...255)
                                    .accessibilityIdentifier("redisDatabaseIndex")
                            }
                        } else {
                            TextField("Database", text: $model.config.database, prompt: Text(databasePrompt))
                                .accessibilityIdentifier("connectionDatabase")
                        }
                    }

                    ConnectionTLSSection(model: model)
                        .id("tls")

                    if model.config.kind == .mongodb {
                        mongoSection
                    } else if model.config.kind == .redis {
                        redisSection
                    }

                    Section {
                        Toggle("Connect through an SSH tunnel", isOn: Binding(get: { model.ssh.isEnabled }, set: { model.ssh.isEnabled = $0 }))
                            .accessibilityIdentifier("sshEnabled")
                        if model.ssh.isEnabled {
                            HStack {
                                TextField("SSH Host", text: Binding(get: { model.ssh.host }, set: { model.ssh.host = $0 }), prompt: Text("bastion.example.com"))
                                TextField("Port", value: Binding(get: { model.ssh.port }, set: { model.ssh.port = $0 }), format: .number.grouping(.never))
                                    .frame(width: 90)
                            }
                            TextField("SSH User", text: Binding(get: { model.ssh.user }, set: { model.ssh.user = $0 }))
                            Picker("Authentication", selection: Binding(get: { model.ssh.authMethod }, set: { model.ssh.authMethod = $0 })) {
                                ForEach(SSHAuthMethod.allCases) { method in
                                    Text(method.displayName).tag(method)
                                }
                            }
                            if model.ssh.authMethod == .keyFile {
                                HStack {
                                    TextField("Private Key", text: Binding(get: { model.ssh.keyPath }, set: { model.ssh.keyPath = $0 }), prompt: Text("~/.ssh/id_ed25519"))
                                    Button("Choose…") { model.chooseKey() }
                                }
                                SecureField("Key Passphrase", text: $model.sshSecret, prompt: Text("Leave empty if the key has none"))
                            } else if model.ssh.authMethod == .password {
                                SecureField("SSH Password", text: $model.sshSecret)
                            }
                        }
                    } header: {
                        Text("SSH Tunnel")
                    } footer: {
                        if model.ssh.isEnabled {
                            Text("Uses /usr/bin/ssh. The database host and port above are reached from the SSH server.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                advancedSection
                    .id("advanced")

                Section("Appearance & Safety") {
                    Picker("Environment", selection: $model.config.environment) {
                        ForEach(ConnectionEnvironment.allCases) { environment in
                            Text(environment.displayName).tag(environment)
                        }
                    }
                    HStack {
                        Text("Color")
                        Spacer()
                        ForEach(ConnectionColor.allCases) { color in
                            ColorDot(color: color, selected: model.config.color == color)
                                .onTapGesture { model.config.color = color }
                        }
                    }
                    TextField("Group", text: $model.config.group, prompt: Text("Optional, e.g. Work"))
                    Picker("Safe Mode", selection: $model.config.safeModeLevel) {
                        ForEach(SafeModeLevel.allCases, id: \.self) { level in
                            Label(level.title, systemImage: level.symbolName).tag(level)
                        }
                    }
                    .accessibilityIdentifier("safeMode")
                    Text(model.config.safeModeLevel.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.testState != .idle {
                    Section {
                        testResult
                    }
                    .id("result")
                }
            }
            .formStyle(.grouped)
            .modifier(FormScroller(target: $model.scrollTarget))

            Divider()
            HStack {
                Button {
                    model.test()
                } label: {
                    if model.testState == .testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(model.validationMessage != nil || model.testState == .testing)
                .accessibilityIdentifier("testConnection")
                if let message = model.validationMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.onSave?(model.config, model.password, model.sshSecret, model.tlsSecret, false) }
                    .disabled(model.validationMessage != nil)
                    .accessibilityIdentifier("saveConnection")
                Button("Connect") { model.onSave?(model.config, model.password, model.sshSecret, model.tlsSecret, true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.validationMessage != nil)
                    .accessibilityIdentifier("saveAndConnect")
            }
            .padding(14)
        }
        .frame(width: 520)
        .frame(minHeight: 520)
    }

    private var databasePrompt: String {
        switch model.config.kind {
        case .postgresql: return "Defaults to the user name"
        case .mongodb: return "Optional, first database by default"
        default: return "Optional"
        }
    }

    @ViewBuilder
    private var betaNote: some View {
        let kind = model.config.kind
        if kind.isBeta {
            Text(kind.displayName + " support is in beta: it works, but it has had less testing than PostgreSQL and MySQL.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Connect timeout for servers; query timeout and startup commands for SQL engines.
    @ViewBuilder
    private var advancedSection: some View {
        let kind = model.config.kind
        Section {
            if !kind.isFileBased {
                Stepper("Connect timeout: \(model.config.connectTimeout) s", value: $model.config.connectTimeout, in: 2...120)
            }
            if kind.isSQL {
                LabeledContent("Query timeout") {
                    HStack(spacing: 6) {
                        TextField("Query timeout", value: queryTimeout, format: .number.grouping(.never), prompt: Text("No limit"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .accessibilityIdentifier("queryTimeout")
                        Text("s")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run on connect")
                    TextField("Run on connect", text: startupCommands, prompt: Text(startupPrompt), axis: .vertical)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...8)
                        .accessibilityIdentifier("startupCommands")
                }
            }
        } header: {
            Text("Advanced")
        } footer: {
            if kind.isSQL {
                Text("Query timeout stops a statement from a query tab, or a table page, that runs longer; leave it empty for no limit. Run on connect runs on every new session, reconnects included; a failing statement stops the connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Empty and 0 both mean no limit and are saved as nil.
    private var queryTimeout: Binding<Int?> {
        Binding(get: { model.config.queryTimeout }, set: { model.config.queryTimeout = ($0 ?? 0) > 0 ? $0 : nil })
    }

    private var startupCommands: Binding<String> {
        Binding(
            get: { model.config.startupCommands ?? "" },
            set: { model.config.startupCommands = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var startupPrompt: String {
        switch model.config.kind {
        case .postgresql: return "SET search_path TO app, public;"
        case .mysql, .mariadb: return "SET time_zone = '+00:00';"
        case .sqlite: return "PRAGMA cache_size = -20000;"
        case .duckdb: return "SET threads = 4;"
        case .mongodb, .redis: return ""
        }
    }

    private func option(_ key: ConnectionOption) -> Binding<String> {
        Binding(get: { model.config.option(key) ?? "" }, set: { model.config.setOption(key, $0) })
    }

    @ViewBuilder
    private var mongoSection: some View {
        Section {
            TextField("Connection String", text: option(.mongoConnectionString), prompt: Text("mongodb://user:pass@host:27017/db?replicaSet=rs0"))
                .accessibilityIdentifier("mongoConnectionString")
            TextField("Auth Database", text: option(.mongoAuthSource), prompt: Text("admin"))
            Picker("Auth Mechanism", selection: option(.mongoAuthMechanism)) {
                Text("Automatic").tag("")
                Text("SCRAM-SHA-256").tag("SCRAM-SHA-256")
                Text("SCRAM-SHA-1").tag("SCRAM-SHA-1")
            }
            TextField("Replica Set", text: option(.mongoReplicaSet), prompt: Text("Optional"))
            Picker("Read Preference", selection: option(.mongoReadPreference)) {
                Text("Default").tag("")
                ForEach(["primary", "primaryPreferred", "secondary", "secondaryPreferred", "nearest"], id: \.self) { Text($0).tag($0) }
            }
            Picker("Write Concern", selection: option(.mongoWriteConcern)) {
                Text("Default").tag("")
                ForEach(["majority", "1", "2", "3"], id: \.self) { Text($0).tag($0) }
            }
            Toggle("Use SRV record (mongodb+srv)", isOn: Binding(get: { model.config.option(.mongoSRV) == "true" }, set: { model.config.setOption(.mongoSRV, $0 ? "true" : nil) }))
        } header: {
            Text("MongoDB")
        } footer: {
            Text("A connection string, when filled in, replaces the host, port, user and database above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var redisSection: some View {
        Section("Redis") {
            Picker("Mode", selection: option(.redisMode)) {
                Text("Standalone").tag("")
                Text("Sentinel").tag("sentinel")
                Text("Cluster").tag("cluster")
            }
            .accessibilityIdentifier("redisMode")
            if model.redisMode == "sentinel" {
                TextField("Sentinel Nodes", text: option(.redisNodes), prompt: Text("host1:26379, host2:26379"))
                TextField("Primary Group Name", text: option(.redisSentinelMaster), prompt: Text("mymaster"))
                TextField("Sentinel Username", text: option(.redisSentinelUser), prompt: Text("Optional"))
            } else if model.redisMode == "cluster" {
                TextField("Cluster Seed Nodes", text: option(.redisNodes), prompt: Text("host1:7000, host2:7001"))
            }
            TextField("Key Separator", text: option(.redisKeySeparator), prompt: Text(":"))
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch model.testState {
        case .idle:
            EmptyView()
        case .testing:
            Label("Connecting…", systemImage: "hourglass")
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

private struct ColorDot: View {
    let color: ConnectionColor
    let selected: Bool

    var body: some View {
        ZStack {
            if let nsColor = Theme.color(for: color) {
                Circle().fill(Color(nsColor: nsColor))
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: 1)
                Image(systemName: "slash.circle").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if selected {
                Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
            }
        }
        .frame(width: 16, height: 16)
        .padding(3)
        .contentShape(Rectangle())
        .help(color.rawValue.capitalized)
    }
}

/// Hosts the form in a sheet (or a window when there is nothing to attach it to).
@MainActor
final class ConnectionFormController: NSObject {
    private let window: NSWindow
    private let model: ConnectionFormModel
    private weak var parent: NSWindow?
    private var retainSelf: ConnectionFormController?

    init(config: ConnectionConfig?, parent: NSWindow?, onComplete: @escaping (ConnectionConfig, _ connect: Bool) -> Void) {
        let password = config.flatMap { AppEnvironment.credentials.password(for: $0.id) } ?? ""
        let sshSecret = config.flatMap { AppEnvironment.credentials.sshSecret(for: $0.id) } ?? ""
        let tlsSecret = config.flatMap { AppEnvironment.credentials.tlsSecret(for: $0.id) } ?? ""
        model = ConnectionFormModel(config: config, password: password, sshSecret: sshSecret, tlsSecret: tlsSecret)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = config == nil ? "New Connection" : "Edit Connection"
        window.isRestorable = false
        window.setAccessibilityIdentifier("connectionForm")
        self.parent = parent
        super.init()
        window.contentViewController = NSHostingController(rootView: ConnectionFormView(model: model))
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onSave = { [weak self] config, password, sshSecret, tlsSecret, connect in
            guard let self else { return }
            var config = config
            var password = password
            if let embedded = config.removeEmbeddedPassword(), password.isEmpty {
                password = embedded
            }
            do {
                try AppEnvironment.connections.save(config)
                if config.kind.isFileBased || password.isEmpty {
                    AppEnvironment.credentials.deletePassword(for: config.id)
                } else {
                    try AppEnvironment.credentials.setPassword(password, for: config.id)
                }
                if config.usesSSH, config.ssh?.usesSecret == true, !sshSecret.isEmpty {
                    try AppEnvironment.credentials.setSSHSecret(sshSecret, for: config.id)
                } else {
                    AppEnvironment.credentials.deleteSSHSecret(for: config.id)
                }
                if !config.kind.isFileBased, config.certificates.needsSecret, !tlsSecret.isEmpty {
                    try AppEnvironment.credentials.setTLSSecret(tlsSecret, for: config.id)
                } else {
                    AppEnvironment.credentials.deleteTLSSecret(for: config.id)
                }
                self.dismiss()
                onComplete(config, connect)
            } catch {
                Alerts.showError(error, title: "Could not save the connection", in: self.window)
            }
        }
    }

    var formModel: ConnectionFormModel { model }

    /// The form on screen, for the scripted UI checks.
    private(set) static weak var presented: ConnectionFormController?

    func present() {
        retainSelf = self
        Self.presented = self
        if let parent, parent.isVisible {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The form's window, for the scripted UI checks.
    var formWindow: NSWindow { window }

    func dismiss() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
        retainSelf = nil
    }
}
