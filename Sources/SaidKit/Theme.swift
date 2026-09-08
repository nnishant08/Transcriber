import SwiftUI

// MARK: - Design tokens — the settled Said identity (violet / amber / ink)
//
// Values are the identity's oklch colours converted to sRGB (see CLAUDE.md ▸ Design system for the
// oklch alongside each hex, so future colours are derived in that space rather than eyeballed).
//
// THE ONE RULE: **amber marks whoever is speaking.** The live indicator, the meter, "Listening",
// the record dot, the current-speaker chip and citation chips are amber. Nothing else may compete
// for it at full strength — tokens that merely need to feel warm (the on-device badge, search
// highlights) use the amber TINT family instead.
//
// Violet is the interactive/brand colour: buttons, links, AI surfaces, speaker 1.
// Ink is type and dark grounds. Paper is the canvas.
//
// Two structural rules carried over from the Mac pass, deliberately NOT changed here:
//   • Selection uses the SYSTEM accent, the way Finder and Mail do — brand violet is for brand and
//     AI surfaces, never for "this row is selected".
//   • Radii/metrics live here so layouts inherit them; no view was restyled in the rebrand pass.
//
// PORTABILITY (C4): light/dark resolution goes through `dynamicColor` / `dynamicWhite` in
// PlatformUI.swift — the single AppKit/UIKit seam. Theme itself imports SwiftUI ONLY, so it
// compiles for iOS unchanged and Phase 2's UI uses these same tokens.
//
// Dark-mode counterparts for tokens the identity only specifies in light are derived here (the
// identity sheet draws light only) and are marked `derived`.

public enum Theme {
    private static func dyn(_ light: UInt, _ dark: UInt, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        dynamicColor(light: light, dark: dark, lightAlpha: la, darkAlpha: da)
    }
    private static func solid(_ hex: UInt, _ a: CGFloat = 1) -> Color { Color(PlatformColor(hex: hex, alpha: a)) }

    // MARK: Identity primitives (oklch → sRGB; the source of every token below)
    /// violet 0.52 0.20 288 — primary interactive
    public static let violetHex: UInt      = 0x6949D2
    /// violet pressed 0.42 0.19 288
    public static let violetPressHex: UInt = 0x4F2BAC
    /// violet deep 0.30 0.14 288 — the recording ground
    public static let violetDeepHex: UInt  = 0x2F166E
    /// violet tint 0.90 0.07 288
    public static let violetTintHex: UInt  = 0xDBD7FF
    /// violet tint ink 0.35 0.15 288
    public static let violetTintInkHex: UInt = 0x3B2282
    /// amber 0.78 0.13 68 — live / current speaker
    public static let amberHex: UInt       = 0xEEA753
    /// amber pressed 0.63 0.12 68
    public static let amberPressHex: UInt  = 0xB87A2B
    /// amber tint 0.92 0.07 78
    public static let amberTintHex: UInt   = 0xFFE0B0
    /// amber mark 0.88 0.11 78 — highlight
    public static let amberMarkHex: UInt   = 0xFFCF82
    /// amber ink 0.25 0.06 68 — text on amber
    public static let amberInkHex: UInt    = 0x341B00
    /// amber ink 2 0.45 0.10 68
    public static let amberInk2Hex: UInt   = 0x794900
    /// ink 0.22 0.03 288
    public static let inkHex: UInt         = 0x1A1828
    /// ink pressed 0.15 0.03 288
    public static let inkPressHex: UInt    = 0x0B0917
    /// ink deep 0.19 0.03 288
    public static let inkDeepHex: UInt     = 0x131220
    /// paper 0.96 0.022 288
    public static let paperHex: UInt       = 0xF1F0FF
    /// paper 2 0.975 0.015 288
    public static let paper2Hex: UInt      = 0xF6F5FF
    public static let cardHex: UInt        = 0xFFFFFF
    /// rule / hairline 0.88 0.05 288
    public static let ruleHex: UInt        = 0xD5D3F7
    /// text 2 0.50 0.05 288
    public static let text2Hex: UInt       = 0x615F7F
    /// text 3 0.60 0.04 288
    public static let text3Hex: UInt       = 0x7F7D97

    // MARK: Surfaces
    /// The document canvas — paper / ink-deep.
    public static let windowBG  = dyn(paperHex, inkDeepHex)
    /// Toolbar / header strip sitting on the canvas.
    public static let titlebar  = dyn(paper2Hex, inkHex)
    /// Sidebar fill. Used directly only when Reduce Transparency is on; otherwise the sidebar is a
    /// real `NSVisualEffectView` (see Materials.swift) and this is the fallback underneath it.
    /// Light is `derived`: paper pulled toward violet-tint so the sidebar reads as recessed.
    public static let sidebarBG = dyn(0xE5E3FA, inkHex)
    /// Inspector / right pane — card white over the canvas.
    public static let inspectorBG = dyn(cardHex, inkHex, 0.60, 0.55)
    /// Cards and fields.
    public static let surface   = dyn(cardHex, inkHex)
    /// Hover / selected pill — violet tint / ink pressed.
    public static let surface2  = dyn(violetTintHex, inkPressHex)
    public static let statusBG  = dyn(0x000000, 0x000000, 0.035, 0.22)
    /// Row hover in lists.
    public static let rowHover  = dynamicWhite(light: 0, lightAlpha: 0.045, dark: 1, darkAlpha: 0.055)

    // MARK: Hairlines — the identity's `rule` colour, violet-tinted rather than neutral grey.
    public static let hairline  = dyn(ruleHex, 0x322F46)    // dark derived
    public static let hairline2 = dyn(0xC3C0EE, 0x403D5A)   // derived: one step stronger

    // MARK: Text
    public static let text        = dyn(inkHex, paperHex)          // primary
    public static let text2       = dyn(text2Hex, 0xA8A5C6)        // secondary body (dark derived)
    public static let text3       = dyn(text3Hex, 0x86839F)        // captions, timestamps, hypothesis tail
    public static let textSidebar = dyn(0x4A4863, 0xC6C3DE)        // sidebar rows (derived)

    // MARK: Selection — the SYSTEM accent, not the brand color
    public static let selection     = Color.accentColor
    public static let onSelection   = Color.white
    /// The secondary "also selected" row in a multi-selection.
    public static let selectionSoft = Color.accentColor.opacity(0.12)
    /// The playing line's tinted band in the transcript.
    public static let playingBand   = Color.accentColor.opacity(0.08)

    // MARK: Find / search match highlight — the amber MARK, not full-strength amber, so a page of
    // search hits never reads as a page of live speakers.
    public static let highlight       = solid(amberMarkHex, 0.55)
    public static let highlightActive = solid(amberHex, 0.75)

    // MARK: Live / record — AMBER. The record red is gone (§E3): the record dot, Stop, the meter,
    // "Listening", the timer and the current-speaker marker are all amber, because amber means
    // "this is happening right now".
    public static let record       = solid(amberHex)
    public static let recordText   = dyn(amberInk2Hex, amberHex)
    public static let recordSoft   = solid(amberHex, 0.16)
    public static let recordBorder = solid(amberHex, 0.42)

    // Paused (session held open, capture gated off).
    //
    // DECISION: paused was amber before the rebrand, and amber now means LIVE — the two states can
    // never share a colour. Paused is therefore rendered in the muted ink/text family: a held
    // session reads as *quieted*, which is what it is, and nothing about it competes with the live
    // amber or with violet's "this is interactive".
    public static let pause       = dyn(text2Hex, 0xA8A5C6)
    public static let pauseText   = dyn(0x4A4863, 0xC6C3DE)
    public static let pauseSoft   = dyn(text2Hex, 0xA8A5C6, 0.16, 0.18)
    public static let pauseBorder = dyn(text2Hex, 0xA8A5C6, 0.38, 0.40)

    // MARK: Brand / AI accent — Said violet, the icon ground.
    public static let accent       = solid(violetHex)
    public static let accentSoft   = solid(violetHex, 0.14)
    public static let accentBorder = solid(violetHex, 0.32)
    public static let accentText   = dyn(violetTintInkHex, 0xC3B7FF)

    // AI tint (Summarize sparkle) — violet, per §E3.
    public static let aiTint = solid(violetHex)
    /// The summary panel's 2px top edge. The pink→indigo→teal gradient is GONE — one accent gradient
    /// in a three-colour identity is one too many. Kept as a `LinearGradient` (not a `Color`) purely
    /// so the existing call sites are untouched; both stops are the same violet, i.e. a solid edge.
    public static let summaryEdge = LinearGradient(
        colors: [solid(violetHex), solid(violetHex)],
        startPoint: .leading, endPoint: .trailing)

    // MARK: On-device / success — the amber family (§E3 maps `ok` → amber). Deliberately the TINT
    // and ink-2 tones rather than full-strength amber, so the persistent "On-device · offline"
    // badge never competes with a live recording indicator for attention.
    public static let ok       = solid(amberPressHex)
    public static let okText   = dyn(amberInk2Hex, amberHex)
    public static let okSoft   = solid(amberTintHex, 0.45)
    public static let okBorder = solid(amberPressHex, 0.32)

    // MARK: Speaker palette (diarization chips) — eight hues at the same L/C, rotated in oklch so
    // no chip fights another, cycling for >8 speakers. Speaker 1 is VIOLET and speaker 2 is AMBER,
    // so a two-person recording reads as the brand.
    private static let speakerPalette: [Color] = [
        dyn(0x6851C3, 0xB3A9FF),   // 1 violet
        dyn(0xA54E00, 0xEEA753),   // 2 amber
        dyn(0x00828F, 0x17D0D8),   // 3 teal
        dyn(0xA43687, 0xEE95D1),   // 4 pink
        dyn(0x227E00, 0x89CC7B),   // 5 green
        dyn(0xB63325, 0xFF9685),   // 6 rust
        dyn(0x006AC5, 0x73BDFF),   // 7 blue
        dyn(0x796B00, 0xC4BC4F),   // 8 olive
    ]
    /// Color for a 1-based diarization speaker slot.
    public static func speakerColor(_ slot: Int) -> Color {
        speakerPalette[(max(1, slot) - 1) % speakerPalette.count]
    }
    /// Chip background for a 1-based speaker slot.
    public static func speakerSoft(_ slot: Int) -> Color { speakerColor(slot).opacity(0.15) }

    // MARK: Radii — up from 12/7 to match the identity's softer geometry.
    public static let windowRadius: CGFloat = 14
    public static let controlRadius: CGFloat = 11
    public static let cardRadius: CGFloat = 12
    public static let rowRadius: CGFloat = 8

    // MARK: Metrics
    public static let toolbarHeight: CGFloat = 52
    public static let sidebarWidth: CGFloat = 224
    public static let sessionSidebarWidth: CGFloat = 186
    public static let inspectorWidth: CGFloat = 296

    // MARK: Fonts — structure unchanged: serif for transcript body, system UI for chrome,
    // monospace for timestamps AND (new) labels, counts and eyebrow rules.
    public static let serif = Font.system(size: 16.5, design: .serif)
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Section headers in sidebars ("SESSIONS", "TAGS") — uppercase, mono, tracked.
    public static let sectionHeader = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
}
