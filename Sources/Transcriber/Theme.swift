import SwiftUI
import AppKit

// MARK: - Design tokens (authoritative; dark values from the redesign spec, light equivalents provided)

extension NSColor {
    convenience init(hex: UInt, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
    /// A color that resolves per appearance (light vs dark).
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

enum Theme {
    private static func dyn(_ light: UInt, _ dark: UInt, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        Color(nsColor: .dynamic(light: NSColor(hex: light, alpha: la), dark: NSColor(hex: dark, alpha: da)))
    }
    private static func solid(_ hex: UInt, _ a: CGFloat = 1) -> Color { Color(nsColor: NSColor(hex: hex, alpha: a)) }

    // Surfaces
    static let windowBG  = dyn(0xF4F4F6, 0x1D1E20)
    static let titlebar  = dyn(0xECECEF, 0x252629)
    static let surface   = dyn(0xFFFFFF, 0x26272B)
    static let surface2  = dyn(0xE6E6EA, 0x303137)   // hover / selected pill
    static let statusBG  = dyn(0x000000, 0x000000, 0.05, 0.22)

    // Hairlines (white@8/13% on dark, black@8/12% on light)
    static let hairline  = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08)))
    static let hairline2 = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.13)))

    // Text
    static let text  = dyn(0x1C1C1E, 0xF2F2F5)
    static let text2 = dyn(0x65656B, 0xA0A0A8)
    static let text3 = dyn(0x9A9AA1, 0x6C6C74)   // hypothesis tail + captions

    // Live / record (system red — record dot, Stop, meter, "Listening" only)
    static let record     = solid(0xFF453A)
    static let recordText = dyn(0xD63A30, 0xFF8079)
    static let recordSoft = solid(0xFF453A, 0.16)
    static let recordBorder = solid(0xFF453A, 0.40)

    // Accent (interactive controls, selected source, links)
    static let accent     = solid(0x7E76EC)
    static let accentSoft = solid(0x7E76EC, 0.16)
    static let accentBorder = solid(0x7E76EC, 0.35)
    static let accentText = dyn(0x5B52C9, 0xCFCBFF)

    // AI tint (Summarize sparkle) + summary gradient edge
    static let aiTint = solid(0xB9A8FF)
    static let ok     = solid(0x5DD6B0)
    static let summaryEdge = LinearGradient(
        colors: [solid(0xFF8AD1), solid(0x9B8CFF), solid(0x5FD6C4)],
        startPoint: .leading, endPoint: .trailing)

    // Speaker palette (diarization chips) — 8 distinct hues, light/dark adaptive, cycling for >8
    // speakers. Ordered for adjacent-slot contrast; readable at chip size in both appearances.
    private static let speakerPalette: [Color] = [
        dyn(0x4F6BD8, 0x8FA3F2),   // 1 indigo-blue
        dyn(0xC75B39, 0xF09C7B),   // 2 terracotta
        dyn(0x2E8B6A, 0x6FD0AC),   // 3 green
        dyn(0xA8508F, 0xE08BC9),   // 4 magenta
        dyn(0x8A6D1B, 0xD9BC55),   // 5 ochre
        dyn(0x2D8FA8, 0x6FCFE4),   // 6 teal-cyan
        dyn(0x7A55C7, 0xB79BEF),   // 7 violet
        dyn(0xB04A55, 0xEC909A),   // 8 rose
    ]
    /// Color for a 1-based diarization speaker slot.
    static func speakerColor(_ slot: Int) -> Color {
        speakerPalette[(max(1, slot) - 1) % speakerPalette.count]
    }

    // Radii
    static let windowRadius: CGFloat = 11
    static let controlRadius: CGFloat = 8

    // Fonts
    static let serif = Font.system(size: 16.5, design: .serif)
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
