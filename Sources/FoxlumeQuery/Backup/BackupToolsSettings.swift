import AppKit
import FoxlumeQueryCore
import SwiftUI

/// Settings › Backup Tools: the client tools Backup and Restore run, found automatically or chosen by path, each with
/// the version it reports.
struct BackupToolsSection: View {
    @Binding var settings: AppSettings
    @State private var searches: [BackupTool: BackupToolSearch] = [:]
    @State private var isSearching = false

    var body: some View {
        Section("Backup Tools") {
            ForEach(BackupTool.allCases) { tool in
                row(tool)
            }
            HStack(alignment: .top) {
                Text("Backup and Restore run the PostgreSQL and MySQL client tools installed on this Mac; Foxlume Query does not include them. Found in your shell's PATH, Homebrew and Postgres.app; Choose… picks a copy yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Search Again") { Task { await refresh() } }
                    .disabled(isSearching)
            }
        }
        .task(id: settings.backupToolPaths) { await refresh() }
    }

    private func row(_ tool: BackupTool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(tool.title).font(.system(.body, design: .monospaced))
                if tool.isOptional {
                    Text("optional").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settings.backupToolPath(tool) != nil {
                    Button("Use Detected") { settings.setBackupToolPath(tool, nil) }
                        .controlSize(.small)
                        .help("Forget the chosen path and use the copy Foxlume Query finds")
                }
                Button("Choose…") { choose(tool) }
                    .controlSize(.small)
                    .accessibilityIdentifier("backupToolChoose-\(tool.rawValue)")
            }
            Text(status(tool))
                .font(.caption)
                .foregroundStyle(statusIsProblem(tool) ? Color.orange : Color.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("backupToolStatus-\(tool.rawValue)")
            Text(tool.purpose).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func status(_ tool: BackupTool) -> String {
        guard let search = searches[tool] else { return isSearching ? "Looking…" : "" }
        if search.isOverride {
            guard let chosen = search.chosen else {
                return "\(settings.backupToolPath(tool) ?? "") cannot be run."
            }
            return "\(chosen.version.map { "\($0) · " } ?? "")\(chosen.path) (chosen)"
        }
        guard let chosen = search.chosen else {
            return tool.isOptional ? "Not found." : "Not found. \(tool.isPostgres ? "brew install libpq, or Postgres.app" : "brew install mysql-client (or mariadb)")."
        }
        let others = search.candidates.count - 1
        return "\(chosen.version.map { "\($0) · " } ?? "")\(chosen.path)" + (others > 0 ? " (newest of \(others + 1) found)" : "")
    }

    private func statusIsProblem(_ tool: BackupTool) -> Bool {
        guard let search = searches[tool] else { return false }
        return search.chosen == nil && (search.isOverride || !tool.isOptional)
    }

    private func refresh() async {
        isSearching = true
        let overrides = Dictionary(uniqueKeysWithValues: BackupTool.allCases.map { ($0, settings.backupToolPath($0)) })
        let found = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: BackupTool.allCases.map { tool in
                (tool, BackupToolDiscovery.find(tool, override: overrides[tool] ?? nil))
            })
        }.value
        searches = found
        isSearching = false
    }

    private func choose(_ tool: BackupTool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(tool.executableNames.joined(separator: " or ")) program"
        panel.prompt = "Use"
        let current = settings.backupToolPath(tool) ?? searches[tool]?.chosen?.path
        panel.directoryURL = URL(fileURLWithPath: current.map { ($0 as NSString).deletingLastPathComponent } ?? "/opt/homebrew/bin", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setBackupToolPath(tool, url.path)
    }
}
