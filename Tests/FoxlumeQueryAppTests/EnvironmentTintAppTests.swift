import AppKit
import Testing
@testable import FoxlumeQuery
import FoxlumeQueryCore

extension AppCompletionTests {
    /// The environment tint behind the workspace toolbar, its accent on the tab strip and the Server Activity window's
    /// tint and badge, following the connection's environment and Settings › Appearance while the windows are open.
    @Suite("Environment tint", .serialized)
    @MainActor
    struct EnvironmentTintAppTests {
        private func makeWindow(_ environment: ConnectionEnvironment) async throws -> (WorkspaceWindowController, URL) {
            let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
            let url = directory.appendingPathComponent("tint-\(UUID().uuidString).sqlite")
            let config = ConnectionConfig(name: "fqtest tint", kind: .sqlite, filePath: url.path, environment: environment)
            try AppEnvironment.connections.save(config)
            let workspace = ConnectionWorkspace(config: config, password: "")
            try await workspace.connect()
            let controller = WorkspaceWindowController(workspace: workspace)
            controller.window?.isReleasedWhenClosed = false
            return (controller, url)
        }

        private func close(_ controller: WorkspaceWindowController, _ url: URL) async {
            let id = controller.workspace.config.id
            controller.window?.close()
            await controller.workspace.disconnect()
            try? AppEnvironment.connections.delete(id: id)
            try? FileManager.default.removeItem(at: AppPaths.tabStateDirectory.appendingPathComponent(id.uuidString + ".json"))
            try? FileManager.default.removeItem(at: url)
        }

        private func setEnvironment(_ environment: ConnectionEnvironment, of controller: WorkspaceWindowController) throws {
            var saved = try #require(AppEnvironment.connections.connection(id: controller.workspace.config.id))
            saved.environment = environment
            try AppEnvironment.connections.save(saved)
        }

        @Test func productionWindowIsTintedInItsTitlebar() async throws {
            _ = NSApplication.shared
            let original = AppEnvironment.settings
            defer { AppEnvironment.settings = original }
            AppEnvironment.settings = AppSettings()
            // Test windows are never key; draw them as active, as a scripted run does.
            EnvironmentTintBand.activeOverride = true
            defer { EnvironmentTintBand.activeOverride = nil }
            let (controller, url) = try await makeWindow(.production)
            let band = controller.environmentTint
            let window = try #require(controller.window)
            #expect(band.superview != nil)
            #expect(band.superview === window.standardWindowButton(.closeButton)?.superview)
            #expect(!band.isHidden)
            #expect(band.hitTest(NSPoint(x: 10, y: 10)) == nil)
            let tint = try #require(band.tint)
            #expect(tint.band.alpha > 0.2)
            #expect(tint.band.red > 0.9 && tint.band.green < 0.3)
            #expect(controller.tabs.strip.accentColor != nil)
            #expect(band.frame.width == band.superview?.bounds.width)

            // Inactive windows keep a lighter tint.
            let active = try #require(band.tint)
            EnvironmentTintBand.activeOverride = false
            let inactive = try #require(band.tint)
            EnvironmentTintBand.activeOverride = true
            #expect(inactive.band.alpha < active.band.alpha)

            // Light and dark use their own palette.
            window.appearance = NSAppearance(named: .darkAqua)
            band.refresh()
            let dark = try #require(band.tint)
            window.appearance = NSAppearance(named: .aqua)
            band.refresh()
            let light = try #require(band.tint)
            #expect(dark.band.alpha > light.band.alpha)
            #expect(dark.band.red != light.band.red || dark.band.green != light.band.green)
            await close(controller, url)
        }

        @Test func environmentAndSettingChangesApplyToOpenWindows() async throws {
            _ = NSApplication.shared
            let original = AppEnvironment.settings
            defer { AppEnvironment.settings = original }
            AppEnvironment.settings = AppSettings()
            let (controller, url) = try await makeWindow(.staging)
            let band = controller.environmentTint
            #expect(band.tint != nil)
            let stagingAlpha = band.tint?.band.alpha ?? 0

            // Saving the connection as Local (as the form's Save does) clears the tint and the accent at once.
            try setEnvironment(.local, of: controller)
            await settle(until: { controller.workspace.config.environment == .local })
            #expect(controller.workspace.config.environment == .local)
            #expect(band.tint == nil)
            #expect(band.isHidden)
            #expect(controller.tabs.strip.accentColor == nil)

            // Switching Local on in Settings tints it, fainter than Staging.
            var settings = AppEnvironment.settings
            settings.setTintsToolbar(true, for: .local)
            AppEnvironment.settings = settings
            let local = try #require(band.tint)
            #expect(!band.isHidden)
            #expect(local.band.alpha < stagingAlpha)
            #expect(controller.tabs.strip.accentColor != nil)

            // Production, then Production switched off.
            try setEnvironment(.production, of: controller)
            await settle(until: { controller.workspace.config.environment == .production })
            #expect((band.tint?.band.alpha ?? 0) > stagingAlpha)
            settings = AppEnvironment.settings
            settings.setTintsToolbar(false, for: .production)
            AppEnvironment.settings = settings
            #expect(band.tint == nil)

            // No environment is never tinted, whatever the setting.
            try setEnvironment(.none, of: controller)
            await settle(until: { controller.workspace.config.environment == .none })
            settings = AppEnvironment.settings
            settings.setTintsToolbar(true, for: .none)
            AppEnvironment.settings = settings
            #expect(band.tint == nil)
            await close(controller, url)
        }

        @Test func serverActivityWindowShowsTintAndBadge() async throws {
            _ = NSApplication.shared
            let original = AppEnvironment.settings
            defer { AppEnvironment.settings = original }
            AppEnvironment.settings = AppSettings()
            let (controller, url) = try await makeWindow(.production)
            let activity = ServerActivityWindowController(workspace: controller.workspace, windows: { [] }, openQuery: { _ in })
            let window = try #require(activity.window)
            #expect(activity.environmentBadge.badgeText == "PRODUCTION")
            #expect(activity.environmentTint.superview === window.standardWindowButton(.closeButton)?.superview)
            #expect(activity.environmentTint.tint != nil)
            #expect(window.titlebarAccessoryViewControllers.contains { $0 === activity.environmentBadge })

            try setEnvironment(.development, of: controller)
            await settle(until: { controller.workspace.config.environment == .development })
            #expect(activity.environmentBadge.badgeText == "DEVELOPMENT")
            #expect(activity.environmentTint.tint == nil)
            try setEnvironment(.none, of: controller)
            await settle(until: { controller.workspace.config.environment == .none })
            #expect(activity.environmentBadge.badgeText == nil)
            window.close()
            await close(controller, url)
        }
    }
}
