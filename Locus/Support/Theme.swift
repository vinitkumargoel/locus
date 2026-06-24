import SwiftUI

// MARK: - Color hex helper

extension Color {
    /// Create a Color from a 0xRRGGBB hex value, with optional alpha.
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Theme tokens
//
// One-to-one port of the CSS custom properties in the Locus design
// (`:root` = light, `[data-theme="dark"]` = dark). Injected through the
// SwiftUI environment so every view reads the same palette.

struct Theme {
    // Translucent menu bar text color.
    let menubarText: Color
    // Window surfaces.
    let win: Color
    let side: Color
    let sideActive: Color
    let card: Color
    let card2: Color
    // Text ramp.
    let text: Color
    let text2: Color
    let text3: Color
    // Hairlines.
    let border: Color
    let border2: Color
    // Accent (blue).
    let accent: Color
    let accentSoft: Color
    // Recording / destructive (red).
    let rec: Color
    let recSoft: Color
    // Status.
    let ok: Color
    let warn: Color
    /// Text drawn on a `warn`-filled surface.
    let warnFg: Color
    // Hover wash.
    let hover: Color
    // Drop shadow under floating surfaces.
    let shadowColor: Color
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    /// `var(--ok)` at the soft alpha used for status chips / permission icons.
    var okSoft: Color { ok.opacity(0.13) }

    static let light = Theme(
        menubarText: Color(hex: 0x1D1D1F),
        win: Color(hex: 0xFFFFFF),
        side: Color(hex: 0xECECEE),
        sideActive: Color(hex: 0x000000, alpha: 0.07),
        card: Color(hex: 0xFFFFFF),
        card2: Color(hex: 0xF5F5F7),
        text: Color(hex: 0x1D1D1F),
        text2: Color(hex: 0x6E6E73),
        text3: Color(hex: 0xA1A1A6),
        border: Color(hex: 0x000000, alpha: 0.10),
        border2: Color(hex: 0x000000, alpha: 0.06),
        accent: Color(hex: 0x0A6CFF),
        accentSoft: Color(hex: 0x0A6CFF, alpha: 0.12),
        rec: Color(hex: 0xE8392F),
        recSoft: Color(hex: 0xE8392F, alpha: 0.12),
        ok: Color(hex: 0x2AA454),
        warn: Color(hex: 0xD98A00),
        warnFg: Color(hex: 0x3A2A00),
        hover: Color(hex: 0x000000, alpha: 0.04),
        shadowColor: Color(hex: 0x000000, alpha: 0.40),
        shadowRadius: 35,
        shadowY: 22
    )

    static let dark = Theme(
        menubarText: Color(hex: 0xF5F5F7),
        win: Color(hex: 0x1E1E20),
        side: Color(hex: 0x262628),
        sideActive: Color(hex: 0xFFFFFF, alpha: 0.09),
        card: Color(hex: 0x2A2A2C),
        card2: Color(hex: 0x242426),
        text: Color(hex: 0xF5F5F7),
        text2: Color(hex: 0x9B9BA0),
        text3: Color(hex: 0x6A6A6F),
        border: Color(hex: 0xFFFFFF, alpha: 0.11),
        border2: Color(hex: 0xFFFFFF, alpha: 0.06),
        accent: Color(hex: 0x2F86FF),
        accentSoft: Color(hex: 0x2F86FF, alpha: 0.18),
        rec: Color(hex: 0xFF5247),
        recSoft: Color(hex: 0xFF5247, alpha: 0.16),
        ok: Color(hex: 0x34C46A),
        warn: Color(hex: 0xF0A92B),
        warnFg: Color(hex: 0x2A1F00),
        hover: Color(hex: 0xFFFFFF, alpha: 0.05),
        shadowColor: Color(hex: 0x000000, alpha: 0.62),
        shadowRadius: 35,
        shadowY: 22
    )

    /// Per-speaker accent colors (s1/s2/s3 in the prototype).
    func speakerColor(_ key: String) -> Color {
        switch key {
        case "s1": return Color(hex: 0x2F86FF)
        case "s2": return Color(hex: 0xC0398F)
        case "s3": return Color(hex: 0x2AA454)
        default:   return text2
        }
    }
}

// MARK: - Environment plumbing

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .light
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
