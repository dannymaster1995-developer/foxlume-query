import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct EnvironmentTintTests {
    private static let tinted: [ConnectionEnvironment] = [.production, .staging, .development, .local]

    /// Unified toolbar backgrounds of an active and an inactive window, light and dark, as macOS draws them.
    private static func toolbarBackgrounds(dark: Bool) -> [RGBAColor] {
        dark ? [RGBAColor(hex: "#2B2B2B")!, RGBAColor(hex: "#1E1E1E")!, RGBAColor(hex: "#383838")!]
            : [RGBAColor(hex: "#F6F6F6")!, RGBAColor(hex: "#ECECEC")!, RGBAColor(hex: "#FFFFFF")!]
    }

    @Test func noEnvironmentOrSwitchedOffMeansNoTint() {
        for dark in [false, true] {
            for active in [false, true] {
                #expect(EnvironmentTint.tint(for: .none, enabled: true, dark: dark, active: active) == nil)
                for environment in Self.tinted {
                    #expect(EnvironmentTint.tint(for: environment, enabled: false, dark: dark, active: active) == nil)
                    #expect(EnvironmentTint.tint(for: environment, enabled: true, dark: dark, active: active) != nil)
                }
            }
        }
    }

    @Test func productionIsStrongestThenStaging() throws {
        for dark in [false, true] {
            for active in [false, true] {
                let alpha = { (environment: ConnectionEnvironment) in
                    EnvironmentTint.tint(for: environment, enabled: true, dark: dark, active: active)?.band.alpha ?? 0
                }
                #expect(alpha(.production) > alpha(.staging))
                #expect(alpha(.staging) > alpha(.development))
                #expect(alpha(.development) == alpha(.local))
                #expect(alpha(.local) <= 0.12)
            }
            // Dark windows need a stronger band to read at a glance.
            let light = try #require(EnvironmentTint.tint(for: .production, enabled: true, dark: false, active: true))
            let darkTint = try #require(EnvironmentTint.tint(for: .production, enabled: true, dark: true, active: true))
            #expect(darkTint.band.alpha > light.band.alpha)
        }
    }

    @Test func inactiveWindowsAreMutedNotCleared() throws {
        for environment in Self.tinted {
            for dark in [false, true] {
                let active = try #require(EnvironmentTint.tint(for: environment, enabled: true, dark: dark, active: true))
                let inactive = try #require(EnvironmentTint.tint(for: environment, enabled: true, dark: dark, active: false))
                #expect(inactive.band.alpha < active.band.alpha)
                #expect(inactive.band.alpha > 0)
                #expect(inactive.accent.alpha < active.accent.alpha)
                #expect(inactive.band.red == active.band.red && inactive.band.green == active.band.green)
            }
        }
    }

    @Test func colorsMatchTheEnvironmentBadges() throws {
        // Production reads red, Staging orange, Development blue, Local green.
        let production = try #require(EnvironmentTint.baseColor(for: .production, dark: false))
        #expect(production.red > 0.9 && production.green < 0.3 && production.blue < 0.3)
        let staging = try #require(EnvironmentTint.baseColor(for: .staging, dark: true))
        #expect(staging.red > 0.9 && staging.green > 0.5 && staging.blue < 0.1)
        let development = try #require(EnvironmentTint.baseColor(for: .development, dark: false))
        #expect(development.blue > 0.9 && development.red < 0.1)
        let local = try #require(EnvironmentTint.baseColor(for: .local, dark: true))
        #expect(local.green > 0.7 && local.red < 0.3)
        #expect(EnvironmentTint.baseColor(for: .none, dark: false) == nil)
        // The production band visibly moves the toolbar toward red.
        let band = try #require(EnvironmentTint.tint(for: .production, enabled: true, dark: false, active: true)).band
        let tinted = band.composited(over: Self.toolbarBackgrounds(dark: false)[0])
        #expect(tinted.red - tinted.green > 0.15)
    }

    /// Toolbar labels (labelColor, about 85 % opaque; secondaryLabelColor, about 50 %) stay readable on every band:
    /// WCAG AA for the labels, 3:1 for secondary text, and never far below the untinted toolbar.
    @Test func toolbarTextKeepsItsContrast() throws {
        for dark in [false, true] {
            let text = dark ? RGBAColor.white : RGBAColor.black
            for background in Self.toolbarBackgrounds(dark: dark) {
                for environment in Self.tinted {
                    for active in [false, true] {
                        let band = try #require(EnvironmentTint.tint(for: environment, enabled: true, dark: dark, active: active)).band
                        let surface = band.composited(over: background)
                        var primary = text
                        primary.alpha = 0.85
                        var secondary = text
                        secondary.alpha = 0.5
                        let primaryRatio = primary.composited(over: surface).contrastRatio(with: surface)
                        let secondaryRatio = secondary.composited(over: surface).contrastRatio(with: surface)
                        #expect(primaryRatio >= 4.5, "\(environment) dark=\(dark) active=\(active): \(primaryRatio)")
                        #expect(secondaryRatio >= 3, "\(environment) dark=\(dark) active=\(active): \(secondaryRatio)")
                        // Never much worse than the untinted toolbar.
                        let plain = secondary.composited(over: background).contrastRatio(with: background)
                        #expect(secondaryRatio >= plain * 0.7)
                    }
                }
            }
        }
    }

    @Test func settingsDefaultToProductionAndStagingAndRoundTrip() throws {
        let defaults = AppSettings()
        #expect(defaults.tintsToolbar(for: .production))
        #expect(defaults.tintsToolbar(for: .staging))
        #expect(!defaults.tintsToolbar(for: .development))
        #expect(!defaults.tintsToolbar(for: .local))
        #expect(!defaults.tintsToolbar(for: .none))
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"rowsPerPage": 100}"#.utf8))
        #expect(old.toolbarTintEnvironments == [.production, .staging])
        var settings = AppSettings()
        settings.setTintsToolbar(false, for: .staging)
        settings.setTintsToolbar(true, for: .local)
        settings.setTintsToolbar(true, for: .none)
        #expect(settings.toolbarTintEnvironments == [.production, .local])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.toolbarTintEnvironments == [.production, .local])
        settings.setTintsToolbar(false, for: .production)
        settings.setTintsToolbar(false, for: .local)
        let none = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(none.toolbarTintEnvironments.isEmpty)
    }
}
