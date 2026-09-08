import SwiftUI
import SaidKit

/// A sticker card: solid fill, generous radius, and a HARD offset edge — never a soft blur.
///
/// This is the app's basic surface. The hard `y: 3` edge in the rule colour is what makes the
/// identity read as printed stickers rather than as generic iOS cards.
struct StickerCard<Content: View>: View {
    var fill: Color = Theme.surface
    var radius: CGFloat = 22
    var edge: Color = Theme.hairline2
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(edge)
                    .offset(y: 3)
            )
    }
}

/// A primary action with a 4px pressed edge in its own darker tone, which compresses on press.
struct PressedButton<Label: View>: View {
    enum Kind { case violet, amber, ink }

    var kind: Kind = .violet
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color {
        switch kind {
        case .violet: return Palette.violet
        case .amber:  return Palette.amber
        case .ink:    return Palette.ink
        }
    }
    private var edge: Color {
        switch kind {
        case .violet: return Palette.violetPress
        case .amber:  return Palette.amberPress
        case .ink:    return Palette.inkPress
        }
    }
    /// Text on amber is the dark amber ink; on violet and ink grounds it is white.
    private var ink: Color { kind == .amber ? Palette.amberInk : .white }

    private let depth: CGFloat = 4

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .fill(edge)
                        .offset(y: pressed ? 0 : depth)
                )
                .offset(y: pressed ? depth : 0)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}

/// A pill chip, colour-coded BY MEANING rather than by state alone.
struct Chip: View {
    enum Kind { case on, violet, amber, neutral, white }

    var text: String
    var kind: Kind = .neutral

    private var background: Color {
        switch kind {
        case .on:      return Palette.ink
        case .violet:  return Palette.violetTint
        case .amber:   return Palette.amberTint
        case .neutral: return Theme.surface2
        case .white:   return Theme.surface
        }
    }
    private var foreground: Color {
        switch kind {
        case .on:      return .white
        case .violet:  return Palette.violetTintInk
        case .amber:   return Palette.amberInk2
        case .neutral, .white: return Theme.text2
        }
    }

    var body: some View {
        Text(text)
            .font(Theme.ui(13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .background(background)
            .clipShape(Capsule())
    }
}

/// A mono uppercase eyebrow with a trailing hairline — the section rule from the screens.
struct SectionRule: View {
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Theme.mono(11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Theme.accent)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 2)
                .clipShape(Capsule())
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A speaker's blob, in that slot's palette colour. Cycles past 8, per `Theme.speakerColor`.
struct SpeakerDot: View {
    var slot: Int
    var size: CGFloat = 10

    var body: some View {
        Blob(size: size, color: Theme.speakerColor(slot))
            .accessibilityHidden(true)
    }
}

/// Timestamps, counts and durations — one place, so the format can never drift.
///
/// Formatting goes through `DocumentBuilder.timestamp`, the SAME function the Mac and the
/// transcript markdown use, so `[mm:ss]` cannot mean two different things across platforms.
struct MonoTime: View {
    var seconds: TimeInterval
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
    var color: Color = Theme.text3

    var body: some View {
        Text(DocumentBuilder.timestamp(seconds))
            .font(Theme.mono(size, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .accessibilityLabel(Self.spoken(seconds))
    }

    /// "3 minutes 12 seconds" rather than VoiceOver reading "zero three colon one two".
    static func spoken(_ t: TimeInterval) -> String {
        let total = Int(max(0, t.rounded()))
        let m = total / 60, s = total % 60
        if m == 0 { return "\(s) second\(s == 1 ? "" : "s")" }
        return "\(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s")"
    }
}
