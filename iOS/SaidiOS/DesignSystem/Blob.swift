import SwiftUI
import SaidKit

/// The quote-blob — the identity's single recurring primitive.
///
/// One shape, everywhere, at every scale: the app icon's mark, the record button, list avatars,
/// bullets, the scrubber thumb, the camera shutter, the toggle knob. Three corners at 50%, the
/// fourth (the tail) small, so it reads as a quotation mark rather than a circle.
///
/// If you are about to draw a rounded rectangle that should be a blob, use this instead.
struct Blob: View {
    var size: CGFloat
    var color: Color
    /// Which corner carries the tail. Bottom-leading is the default — a closing quote.
    var tail: Tail = .bottomLeading

    enum Tail { case bottomLeading, bottomTrailing, topLeading, topTrailing }

    /// The tail's radius as a fraction of the blob's own size, so the shape holds at any scale.
    private var tailRadius: CGFloat { size * 0.11 }
    private var round: CGFloat { size / 2 }

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: tail == .topLeading ? tailRadius : round,
            bottomLeadingRadius: tail == .bottomLeading ? tailRadius : round,
            bottomTrailingRadius: tail == .bottomTrailing ? tailRadius : round,
            topTrailingRadius: tail == .topTrailing ? tailRadius : round,
            style: .continuous
        )
        .fill(color)
        .frame(width: size, height: size)
    }
}

/// The paired mark — a light blob and an amber one — as on the app icon and the record button.
struct BlobPair: View {
    var size: CGFloat
    var gap: CGFloat? = nil
    var leading: Color = .white
    var trailing: Color = Palette.amber

    var body: some View {
        HStack(spacing: gap ?? size * 0.26) {
            Blob(size: size, color: leading)
            Blob(size: size, color: trailing)
        }
    }
}

/// Concrete identity colours, resolved once from `Theme`'s hex primitives.
///
/// This is NOT a second palette: every value here is a `Theme` token. It exists so screens can say
/// `Palette.violet` instead of repeating `Color(PlatformColor(hex: Theme.violetHex))`, and so there
/// is still exactly one place a colour can come from.
enum Palette {
    private static func c(_ hex: UInt) -> Color { Color(PlatformColor(hex: hex)) }

    static let violet     = c(Theme.violetHex)
    static let violetPress = c(Theme.violetPressHex)
    static let violetDeep = c(Theme.violetDeepHex)
    static let violetTint = c(Theme.violetTintHex)
    static let violetTintInk = c(Theme.violetTintInkHex)
    static let amber      = c(Theme.amberHex)
    static let amberPress = c(Theme.amberPressHex)
    static let amberTint  = c(Theme.amberTintHex)
    static let amberMark  = c(Theme.amberMarkHex)
    static let amberInk   = c(Theme.amberInkHex)
    static let amberInk2  = c(Theme.amberInk2Hex)
    static let ink        = c(Theme.inkHex)
    static let inkPress   = c(Theme.inkPressHex)
    static let inkDeep    = c(Theme.inkDeepHex)
    static let paper      = c(Theme.paperHex)
    static let paper2     = c(Theme.paper2Hex)
    static let card       = c(Theme.cardHex)
    static let rule       = c(Theme.ruleHex)
}
