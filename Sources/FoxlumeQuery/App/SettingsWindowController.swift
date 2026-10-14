import AppKit
import FoxlumeQueryCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var settings = AppEnvironment.settings
    @State private var themes = ThemeStore.shared.themes
    @State private var importMessage: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearanceMode")
                Text("System follows macOS. Light and Dark apply to every Foxlume Query window, whatever macOS uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Theme") {
                themePicker("Light theme", selection: $settings.lightThemeID)
                themePicker("Dark theme", selection: $settings.darkThemeID)
                HStack(spacing: 12) {
                    ThemePreview(theme: theme(settings.lightThemeID))
                    ThemePreview(theme: theme(settings.darkThemeID))
                }
                HStack {
                    Button("Import Theme…") { importTheme() }
                        .help("Import a VS Code color theme (.json) or extension (.vsix)")
                        .accessibilityIdentifier("importTheme")
                    Button("Themes Folder") {
                        let folder = AppPaths.dataDirectory.appendingPathComponent("themes", isDirectory: true)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    Spacer()
                    if let removable = [settings.lightThemeID, settings.darkThemeID].compactMap({ id in themes.first { $0.id == id && !$0.isBuiltIn } }).first {
                        Button("Delete Theme", role: .destructive) { delete(removable) }
                            .help("Delete “\(removable.name)”")
                    }
                }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Themes color the SQL editor, data grids and window background. Import a VS Code color theme (.json) or a whole extension (.vsix), such as Dracula or One Dark Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Connections") {
                Picker("Check connection health", selection: $settings.connectionHealthCheck) {
                    ForEach(ConnectionHealthCheck.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("A connection that stops answering reconnects in the background. With “Only when I use the connection” it reconnects when you next run something.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Data Grid") {
                Picker("Rows per page", selection: $settings.rowsPerPage) {
                    ForEach([100, 200, 500, 1000, 2000, 5000], id: \.self) { Text("\($0)").tag($0) }
                }
                Stepper("Font size: \(Int(settings.gridFontSize)) pt", value: $settings.gridFontSize, in: 9...20, step: 1)
                Toggle("Show row numbers", isOn: $settings.showRowNumbers)
                Toggle("Show system databases (mysql, sys, information_schema, admin…)", isOn: $settings.showSystemDatabases)
            }
            Section("SQL Editor") {
                Stepper("Font size: \(Int(settings.editorFontSize)) pt", value: $settings.editorFontSize, in: 9...28, step: 1)
                Toggle("Suggest completions while typing", isOn: $settings.autocompleteOnTyping)
                Picker("Keyword case", selection: $settings.keywordCase) {
                    ForEach(KeywordCase.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("keywordCase")
                Text("Applies to completed keywords and functions. UPPERCASE and lowercase also re-case keywords as you type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Keep at most", selection: $settings.queryRowLimit) {
                    ForEach([1000, 5000, 10_000, 50_000, 100_000], id: \.self) { Text("\($0) rows").tag($0) }
                }
            }
            Section("Safety") {
                Toggle("Confirm data changes on Production connections", isOn: $settings.confirmWritesOnProduction)
                Toggle("Confirm UPDATE and DELETE without WHERE", isOn: $settings.confirmUnboundedWrites)
            }
            Section("Storage") {
                LabeledContent("Data folder") {
                    Text(AppPaths.dataDirectory.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                LabeledContent("Passwords") {
                    Text(AppPaths.isPortable ? "Private file in the data folder (portable mode)" : "macOS Keychain")
                }
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.dataDirectory])
                }
            }
            Text("Font and page size changes apply to tabs opened afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 520)
        .onChange(of: settings) { newValue in
            if AppEnvironment.settings != newValue { AppEnvironment.settings = newValue }
        }
        // A change made elsewhere must show here, or the next edit would write the stale copy back.
        .onReceive(NotificationCenter.default.publisher(for: SettingsStore.didChangeNotification)) { _ in
            let current = AppEnvironment.settings
            if current != settings { settings = current }
        }
    }

    private func theme(_ id: String) -> ThemeDefinition {
        themes.first { $0.id == id } ?? BuiltInThemes.defaultLight
    }

    private func themePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(themes) { theme in
                Text(theme.name + (theme.isBuiltIn ? "" : " (imported)") + "  ·  " + (theme.appearance == .dark ? "dark" : "light")).tag(theme.id)
            }
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json] + ([UTType(filenameExtension: "vsix")].compactMap { $0 })
        panel.allowsMultipleSelection = true
        panel.message = "Choose VS Code color themes (.json) or extensions (.vsix)"
        guard panel.runModal() == .OK else { return }
        var imported: [ThemeDefinition] = []
        var failures: [String] = []
        for url in panel.urls {
            do {
                imported += try ThemeStore.shared.importThemes(from: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        themes = ThemeStore.shared.themes
        if let light = imported.first(where: { $0.appearance == .light }) { settings.lightThemeID = light.id }
        if let dark = imported.first(where: { $0.appearance == .dark }) { settings.darkThemeID = dark.id }
        let names = imported.map(\.name).joined(separator: ", ")
        importMessage = [imported.isEmpty ? nil : "Imported \(names).", failures.isEmpty ? nil : failures.joined(separator: "\n")].compactMap { $0 }.joined(separator: "\n")
    }

    private func delete(_ theme: ThemeDefinition) {
        ThemeStore.shared.delete(id: theme.id)
        if settings.lightThemeID == theme.id { settings.lightThemeID = BuiltInThemes.defaultLightID }
        if settings.darkThemeID == theme.id { settings.darkThemeID = BuiltInThemes.defaultDarkID }
        themes = ThemeStore.shared.themes
    }
}

/// A few lines of highlighted SQL drawn with a theme's colors.
struct ThemePreview: View {
    let theme: ThemeDefinition

    private func color(_ slot: ThemeSlot, _ fallback: Color) -> Color {
        theme.colors[slot].flatMap(ThemeManager.nsColor).map { Color(nsColor: $0) } ?? fallback
    }

    var body: some View {
        let keyword = color(.syntaxKeyword, Color(nsColor: .systemPink))
        let string = color(.syntaxString, Color(nsColor: .systemRed))
        let number = color(.syntaxNumber, Color(nsColor: .systemBlue))
        let comment = color(.syntaxComment, .secondary)
        let text = color(.editorForeground, .primary)
        let function = color(.syntaxFunction, Color(nsColor: .systemPurple))
        VStack(alignment: .leading, spacing: 3) {
            (Text("SELECT ").foregroundColor(keyword) + Text("name, ").foregroundColor(text) + Text("COUNT").foregroundColor(function) + Text("(*)").foregroundColor(text))
            (Text("FROM ").foregroundColor(keyword) + Text("orders ").foregroundColor(text) + Text("WHERE ").foregroundColor(keyword) + Text("total > ").foregroundColor(text) + Text("42").foregroundColor(number))
            (Text("AND ").foregroundColor(keyword) + Text("status = ").foregroundColor(text) + Text("'paid'").foregroundColor(string))
            Text("-- \(theme.name)").foregroundColor(comment)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color(.editorBackground, theme.appearance == .dark ? Color(white: 0.12) : .white)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isRestorable = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
