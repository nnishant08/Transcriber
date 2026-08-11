import SwiftUI
import AppKit

// MARK: - Design tokens
//
// Authoritative values come from the "Transcriber UI v3 — Mac-native pass" design (claude.ai/design).
// v3 draws light mode only, so every token below pairs the v3 light value with a derived dark one.
//
// Two rules from v3 that the palette encodes:
//   • Selection uses the SYSTEM accent (`.controlAccentColor`), the way Finder and Mail do — brand
//     purple is for brand and AI surfaces, never for "this row is selected".
//   • Record red is only ever the record dot, Stop, the meter, and "Listening".

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

    // MARK: Surfaces
    /// The document canvas (v3 #F6F6F4).
    static let windowBG  = dyn(0xF6F6F4, 0x1E1F21)
    /// Toolbar / header strip sitting on the canvas (v3 rgba(246,246,244,.96)).
    static let titlebar  = dyn(0xF6F6F4, 0x252629)
    /// Sidebar fill. Used directly only when Reduce Transparency is on; otherwise the sidebar is a
    /// real `NSVisualEffectView` (see Materials.swift) and this is the fallback underneath it.
    static let sidebarBG = dyn(0xE9E8E5, 0x232427)
    /// Inspector / right pane (v3 rgba(255,255,255,.6) over the canvas).
    static let inspectorBG = dyn(0xFFFFFF, 0x232427, 0.60, 0.55)
    /// Cards and fields.
    static let surface   = dyn(0xFFFFFF, 0x26272B)
    static let surface2  = dyn(0xE6E6EA, 0x303137)   // hover / selected pill
    static let statusBG  = dyn(0x000000, 0x000000, 0.035, 0.22)
    /// Row hover in lists.
    static let rowHover  = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.045),
                                                   dark: NSColor(white: 1, alpha: 0.055)))

    // MARK: Hairlines (v3 uses rgba(0,0,0,.07….14) at four weights; two are enough)
    static let hairline  = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08)))
    static let hairline2 = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.14)))

    // MARK: Text (v3's four tiers)
    static let text        = dyn(0x1B1B1D, 0xF2F2F5)   // primary
    static let text2       = dyn(0x6A6A70, 0xA0A0A8)   // secondary body
    static let text3       = dyn(0x98989F, 0x8A8A93)   // captions, timestamps, hypothesis tail
    static let textSidebar = dyn(0x4A4A50, 0xC2C2CA)   // sidebar rows (v3 #4A4A50)

    // MARK: Selection — the SYSTEM accent, not the brand color
    static let selection     = Color(nsColor: .controlAccentColor)
    static let onSelection   = Color.white
    /// The secondary "also selected" row in a multi-selection (v3 rgba(10,105,216,.1)).
    static let selectionSoft = Color(nsColor: .controlAccentColor).opacity(0.12)
    /// The playing line's tinted band in the transcript (v3 rgba(10,105,216,.07)).
    static let playingBand   = Color(nsColor: .controlAccentColor).opacity(0.08)

    // MARK: Find / search match highlight (v3 rgba(255,214,10,.5))
    static let highlight       = solid(0xFFD60A, 0.50)
    static let highlightActive = solid(0xFFB800, 0.75)

    // MARK: Live / record (v3 #E0342A — record dot, Stop, meter, "Listening" only)
    static let record       = solid(0xE0342A)
    static let recordText   = dyn(0xC0281F, 0xFF8079)
    static let recordSoft   = solid(0xE0342A, 0.13)
    static let recordBorder = solid(0xE0342A, 0.38)

    // Paused (session held open, capture gated off) — amber, so it can never be mistaken for
    // recording (red) or for an ordinary interactive control (accent).
    static let pause       = solid(0xF0A93B)
    static let pauseText   = dyn(0xA9701A, 0xF6C87A)
    static let pauseSoft   = solid(0xF0A93B, 0.16)
    static let pauseBorder = solid(0xF0A93B, 0.38)

    // MARK: Brand / AI accent — Said violet (#6949D2 = oklch(0.52 0.20 288), the icon ground)
    static let accent       = solid(0x6949D2)
    static let accentSoft   = solid(0x6949D2, 0.14)
    static let accentBorder = solid(0x6949D2, 0.32)
    static let accentText   = dyn(0x3D2A94, 0xCFC4FF)

    // AI tint (Summarize sparkle) + summary gradient edge.
    // Deliberately a LIGHTER VIOLET, not the brand amber: amber is already the paused-state
    // colour above, and the whole point of that choice is that amber can only ever mean
    // "held". The logo's amber stroke stays a brand-surface colour, not a UI-state one.
    static let aiTint = solid(0x9B84F0)
    static let summaryEdge = LinearGradient(
        colors: [solid(0xFF8AD1), solid(0x9B84F0), solid(0x5FD6C4)],
        startPoint: .leading, endPoint: .trailing)

    // MARK: On-device / success (v3 #2D966E)
    static let ok       = solid(0x2D966E)
    static let okText   = dyn(0x1F7A5C, 0x6FD0AC)
    static let okSoft   = solid(0x2D966E, 0.13)
    static let okBorder = solid(0x2D966E, 0.30)

    // MARK: Speaker palette (diarization chips) — 8 distinct hues, light/dark adaptive, cycling for
    // >8 speakers. Slots 1–3 are v3's drawn values. Ordered for adjacent-slot contrast.
    private static let speakerPalette: [Color] = [
        dyn(0x3A55C4, 0x8FA3F2),   // 1 indigo-blue
        dyn(0xA8461F, 0xF09C7B),   // 2 terracotta
        dyn(0x1F7A5C, 0x6FD0AC),   // 3 green
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
    /// Chip background for a 1-based speaker slot (v3 draws the hue at 15%).
    static func speakerSoft(_ slot: Int) -> Color { speakerColor(slot).opacity(0.15) }

    // MARK: Radii
    static let windowRadius: CGFloat = 12
    static let controlRadius: CGFloat = 7
    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 6

    // MARK: Metrics (v3 measures its chrome consistently)
    static let toolbarHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 224
    static let sessionSidebarWidth: CGFloat = 186
    static let inspectorWidth: CGFloat = 296

    // MARK: Fonts
    static let serif = Font.system(size: 16.5, design: .serif)
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Section headers in sidebars ("SESSIONS", "TAGS") — v3 10.5px/600/.09em uppercase.
    static let sectionHeader = Font.system(size: 10.5, weight: .semibold)
}
