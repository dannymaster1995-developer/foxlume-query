import Foundation

/// The color of the band behind the statement at the caret, derived from an editor theme so it suits built-in and
/// imported themes alike: the background moved a little toward the selection color (or the current line color), or
/// just far enough toward the text color when that is too close to the background to show.
public enum StatementBandColor {
    /// How far the background moves toward the selection color.
    static let selectionAmount = 0.3
    /// The least visible difference from the background, as the largest change of one RGB channel.
    static let minimumDistance = 0.03
    /// The band never moves further than this toward the text color, so text on it stays readable.
    static let maximumTextAmount = 0.12

    /// An opaque color. Translucent theme colors are painted over the background first.
    public static func color(background: RGBAColor, selection: RGBAColor?, currentLine: RGBAColor?, foreground: RGBAColor?, dark: Bool) -> RGBAColor {
        let base = background.composited(over: dark ? .black : .white)
        let text = (foreground ?? (dark ? .white : .black)).composited(over: base)
        var band = base
        if let tint = (selection ?? currentLine)?.composited(over: base) {
            band = base.mixed(with: tint, amount: selectionAmount)
        }
        if distance(band, base) < minimumDistance {
            let span = distance(text, base)
            if span > 0 { band = base.mixed(with: text, amount: min(maximumTextAmount, minimumDistance / span)) }
        }
        return band
    }

    /// The current line where it lies in the band: the band moved by as much as the theme's current line differs
    /// from the background, so the caret's line still stands out without punching a hole in the band.
    public static func currentLine(band: RGBAColor, background: RGBAColor, currentLine: RGBAColor, dark: Bool) -> RGBAColor {
        let base = background.composited(over: dark ? .black : .white)
        let line = currentLine.composited(over: base)
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        return RGBAColor(
            red: clamp(band.red + line.red - base.red),
            green: clamp(band.green + line.green - base.green),
            blue: clamp(band.blue + line.blue - base.blue)
        )
    }

    /// The largest difference of one RGB channel.
    public static func distance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }
}

public extension RGBAColor {
    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)

    /// WCAG relative luminance, from sRGB with gamma removed.
    var relativeLuminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two opaque colors, from 1 to 21.
    func contrastRatio(with other: RGBAColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
