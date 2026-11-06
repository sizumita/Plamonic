import AppKit

/// Colors for overlays and popups. Text colors keep a WCAG contrast of at least 7:1 (primary)
/// and 4.5:1 (secondary) against the opaque background in both themes.
struct OverlayPalette: Equatable {
    var isDark: Bool
    /// Background with the user's opacity applied.
    var background: NSColor
    /// Opaque version of `background` (for contrast checks and indicator fills).
    var solidBackground: NSColor
    var border: NSColor
    var text: NSColor
    /// Partial (streaming) text and placeholders.
    var secondaryText: NSColor
    /// Draft indicator.
    var indicator: NSColor

    static func make(theme: OverlayTheme, systemIsDark: Bool, backgroundOpacity: Double) -> OverlayPalette {
        let dark: Bool
        switch theme {
        case .system: dark = systemIsDark
        case .light: dark = false
        case .dark: dark = true
        }
        let opacity = CGFloat(min(max(backgroundOpacity, 0), 1))
        if dark {
            let bg = srgb(0.125, 0.125, 0.137)
            return OverlayPalette(
                isDark: true,
                background: bg.withAlphaComponent(opacity),
                solidBackground: bg,
                border: srgb(1, 1, 1, 0.14),
                text: srgb(0.953, 0.953, 0.961),
                secondaryText: srgb(0.655, 0.655, 0.686),
                indicator: srgb(0.392, 0.678, 1.0))
        }
        let bg = srgb(0.988, 0.988, 0.980)
        return OverlayPalette(
            isDark: false,
            background: bg.withAlphaComponent(opacity),
            solidBackground: bg,
            border: srgb(0, 0, 0, 0.13),
            text: srgb(0.102, 0.102, 0.118),
            secondaryText: srgb(0.396, 0.396, 0.427),
            indicator: srgb(0.0, 0.42, 0.85))
    }

    /// Resolves `.system` against a view's effective appearance.
    static func make(appearance: OverlayAppearance, effectiveAppearance: NSAppearance) -> OverlayPalette {
        make(
            theme: appearance.theme, systemIsDark: isDark(effectiveAppearance),
            backgroundOpacity: appearance.backgroundOpacity)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Below this relative luminance a color reads as dark: white contrasts with it more than black does.
    static let darkLuminance = 0.179
    /// Least contrast a matched text color needs against its background; below it the palette's text is used.
    static let minimumTextContrast: CGFloat = 3
    /// Partial (streaming) text is drawn a little dimmer.
    static let streamingTextAlpha: CGFloat = 0.7

    /// Colors for one overlay item, in order of preference:
    /// - background: measured from the window (with the user's opacity), else the palette, dark or light by
    ///   the original text's color (light text = dark app) when the theme follows the system, else by the theme;
    /// - text: the measured text color, else the original's color, else the palette's, whichever first
    ///   contrasts enough with the background.
    static func resolve(
        _ colors: OverlayItemColors, appearance: OverlayAppearance, systemIsDark: Bool
    ) -> ResolvedOverlayColors {
        let dark: Bool
        if let background = colors.sampled?.background {
            dark = background.luminance < darkLuminance
        } else if appearance.theme == .system, let text = colors.originalText {
            dark = text.luminance >= darkLuminance
        } else {
            switch appearance.theme {
            case .system: dark = systemIsDark
            case .light: dark = false
            case .dark: dark = true
            }
        }
        let palette = make(theme: dark ? .dark : .light, systemIsDark: dark, backgroundOpacity: appearance.backgroundOpacity)
        let solid: NSColor
        let background: NSColor
        if let sampled = colors.sampled?.background {
            solid = nsColor(sampled, alpha: 1)
            background = solid.withAlphaComponent(CGFloat(min(max(appearance.backgroundOpacity, 0), 1)))
        } else {
            solid = palette.solidBackground
            background = palette.background
        }
        // Translucent text colors are flattened onto the background first, so the contrast check sees
        // what is drawn.
        let candidates = [colors.sampled?.text, colors.originalText].compactMap { $0 }.map { flatten($0, on: solid) }
        var text = candidates.first { contrastRatio($0, solid) >= minimumTextContrast } ?? palette.text
        if text == palette.text, contrastRatio(text, solid) < 4.5 {
            // A measured background the palette was not made for.
            text = relativeLuminance(solid) < CGFloat(darkLuminance) ? srgb(0.953, 0.953, 0.961) : srgb(0.102, 0.102, 0.118)
        }
        return ResolvedOverlayColors(
            isDark: dark, background: background, solidBackground: solid, text: text,
            streamingText: text.withAlphaComponent(streamingTextAlpha),
            indicator: palette.indicator.withAlphaComponent(0.8))
    }

    static func nsColor(_ color: RGBAColor, alpha: Double? = nil) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
            alpha: CGFloat(alpha ?? color.alpha))
    }

    /// `color` composited over an opaque `background`.
    static func flatten(_ color: RGBAColor, on background: NSColor) -> NSColor {
        let a = CGFloat(min(max(color.alpha, 0), 1))
        guard a < 1, let bg = background.usingColorSpace(.sRGB) else { return nsColor(color, alpha: 1) }
        return srgb(
            CGFloat(color.red) * a + bg.redComponent * (1 - a), CGFloat(color.green) * a + bg.greenComponent * (1 - a),
            CGFloat(color.blue) * a + bg.blueComponent * (1 - a))
    }

    /// WCAG 2 contrast ratio between two colors (alpha ignored), 1...21.
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Where an item's colors come from.
struct OverlayItemColors: Hashable, Sendable {
    /// Measured from the target window's own pixels.
    var sampled: SampledColors?
    /// The original text's color as the app reports it (only when matching the original's look).
    var originalText: RGBAColor?

    init(sampled: SampledColors? = nil, originalText: RGBAColor? = nil) {
        self.sampled = sampled
        self.originalText = originalText
    }
}

/// The colors one overlay item is drawn with.
struct ResolvedOverlayColors: Equatable {
    var isDark: Bool
    /// With the user's opacity applied.
    var background: NSColor
    var solidBackground: NSColor
    var text: NSColor
    var streamingText: NSColor
    var indicator: NSColor
}
