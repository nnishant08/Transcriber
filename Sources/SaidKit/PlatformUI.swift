import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - The ONE UI platform seam in SaidKit
//
// Every `#if canImport(AppKit)` in the core lives in this file, on purpose. Both branches are real
// implementations of the same contract — never a macOS body with an iOS stub that traps (directive
// 4). Two things genuinely differ between the platforms and cannot be expressed in SwiftUI alone:
//
//   1. A concrete font/colour class. `NSAttributedString`'s RTF serialization (Exporter) needs a
//      real `NSFont`/`UIFont` — a CoreText font does not round-trip into RTF.
//   2. Resolving a light/dark colour pair at DRAW time rather than at construction time, which is
//      what makes `Theme`'s tokens follow the system appearance (C4).
//
// Anything that can be done with CoreGraphics/CoreText instead is done that way and does not
// appear here — see `ClipExporter.drawCaption`.

#if canImport(AppKit)
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#elseif canImport(UIKit)
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

public extension PlatformColor {
    /// A colour from a 24-bit RGB hex literal, in the sRGB space on both platforms.
    convenience init(hex: UInt, alpha: CGFloat = 1) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        #if canImport(AppKit)
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
        #else
        self.init(red: r, green: g, blue: b, alpha: alpha)
        #endif
    }

    /// A colour that resolves per appearance (light vs dark) when it is DRAWN, not when it is built.
    ///
    /// macOS: `NSColor(name:)` with an appearance-matching block — the app's existing behaviour,
    /// unchanged. iOS: `UIColor(dynamicProvider:)` keyed off the trait collection's user interface
    /// style. Same contract, two real implementations.
    static func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if canImport(AppKit)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        #else
        return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        #endif
    }

    /// The system's secondary label colour. The two platforms spell it differently
    /// (`secondaryLabelColor` vs `secondaryLabel`), so the seam names it once.
    static var secondaryLabelCompat: PlatformColor {
        #if canImport(AppKit)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }
}

public extension NSAttributedString {
    /// Serialize to RTF.
    ///
    /// macOS keeps the exact call the exporter has always made (`rtf(from:documentAttributes:)`,
    /// AppKit-only, non-throwing, returns `Data?`) so RTF output is byte-identical. UIKit does not
    /// vend `rtf(...)`, so iOS uses the throwing `data(from:documentAttributes:)` with the same RTF
    /// document type. Same contract, two real implementations.
    func saidRTFData() -> Data? {
        let range = NSRange(location: 0, length: length)
        #if canImport(AppKit)
        return rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #else
        return try? data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #endif
    }
}

/// A SwiftUI `Color` that follows the system appearance, built from a light/dark hex pair.
/// This is the single primitive every `Theme` token is defined in terms of.
public func dynamicColor(light: UInt, dark: UInt,
                         lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
    Color(PlatformColor.dynamic(light: PlatformColor(hex: light, alpha: lightAlpha),
                                dark: PlatformColor(hex: dark, alpha: darkAlpha)))
}

/// A SwiftUI `Color` that follows the system appearance, built from a light/dark WHITE level
/// (used for hairlines and hover fills, which are neutral rather than tinted).
public func dynamicWhite(light: CGFloat, lightAlpha: CGFloat,
                         dark: CGFloat, darkAlpha: CGFloat) -> Color {
    #if canImport(AppKit)
    let l = NSColor(white: light, alpha: lightAlpha)
    let d = NSColor(white: dark, alpha: darkAlpha)
    #else
    let l = UIColor(white: light, alpha: lightAlpha)
    let d = UIColor(white: dark, alpha: darkAlpha)
    #endif
    return Color(PlatformColor.dynamic(light: l, dark: d))
}
