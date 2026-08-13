import AppKit
import Foundation

// Renders the "Said." app icon: two quotation strokes on a squircle.
//
// Geometry comes from the brand doc as RATIOS, not pixels, so every size is drawn
// natively rather than downscaled from 1024 — that is what keeps the 16pt and 32pt
// menu-bar/dock renderings crisp.
//
// Usage: swift GenerateIcon.swift <output.png> [--size N] [--variant violet|ink|paper]

// MARK: - Palette
// sRGB conversions of the oklch tokens in the brand doc. Keep these two in sync:
//   violet oklch(0.52 0.20 288) · amber oklch(0.78 0.13 68)
//   ink    oklch(0.22 0.03 288) · paper oklch(0.975 0.008 288)
let violet   = NSColor(srgbRed: 105/255, green:  73/255, blue: 210/255, alpha: 1)
let amber    = NSColor(srgbRed: 238/255, green: 167/255, blue:  83/255, alpha: 1)
let ink      = NSColor(srgbRed:  26/255, green:  24/255, blue:  40/255, alpha: 1)
let paper    = NSColor(srgbRed: 246/255, green: 246/255, blue: 252/255, alpha: 1)
let offWhite = NSColor(srgbRed: 245/255, green: 245/255, blue: 248/255, alpha: 1)

struct Variant {
    let ground: NSColor
    let voiceA: NSColor  // leading stroke
    let voiceB: NSColor  // trailing stroke — always the amber accent
}

let variants: [String: Variant] = [
    "violet": Variant(ground: violet, voiceA: .white,   voiceB: amber),
    "ink":    Variant(ground: ink,    voiceA: offWhite, voiceB: amber),
    "paper":  Variant(ground: paper,  voiceA: violet,   voiceB: amber),
]

// MARK: - Geometry
// The body sits on Apple's macOS icon grid: 824 of a 1024 canvas, leaving the
// surrounding padding the platform expects. Mark ratios are relative to the body.
let bodyRatio: CGFloat = 824.0 / 1024.0
let blobRatio: CGFloat =  48.0 / 176.0   // 27.3% of the body
var gapRatio:  CGFloat =  12.0 / 176.0   //  6.8% of the body
/// Tail corner radius as a fraction of the STROKE width.
/// This is the number that decides whether the mark reads as a quote or as a blob.
/// The settled identity specifies the fourth corner at 3% of the ICON EDGE (see the iPhone screens
/// and CLAUDE.md ▸ Design system). On the 1024 grid: 3% × 1024 = 30.7px against a 225px blob.
var tailFraction: CGFloat = 30.7 / 225.0   // 13.6% of the stroke = 3% of the icon edge
let squircleExponent: CGFloat = 5.0      // superellipse power; ~Apple's continuous corner
/// "doc" = the settled identity's form — a circle with three 50% corners and a small squared
/// fourth corner (the tail), i.e. CSS `border-radius: 50% 50% 50% 3%`. This is what the iPhone
/// screens draw at every scale, from the 70px record button down to the 7px bullet, so the app
/// icon uses it too and the mark is ONE drawing everywhere.
/// "comma" = an earlier tapered exploration, kept for comparison (SHAPE=comma).
var shape = "doc"
var commaReach: CGFloat = 1.62           // tail tip distance, in bowl radii
/// Tail direction in degrees. 225 = down-left (a closing quote / comma);
/// 45 = up-right (an opening quote, the 180° rotation of the same form).
var commaAngle: CGFloat = 225

/// Apple-style squircle (superellipse), not a circular-corner rounded rect — the
/// difference is visible at 512pt+ beside native icons.
func squirclePath(in rect: NSRect, n: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// A tapered comma: the bowl is a circle, the tail is the two tangent lines from a
/// point below-left of it. Unlike the squared-corner form, the taper is most of the
/// outline, which is what makes it read as punctuation rather than as a blob.
func commaPath(x: CGFloat, y: CGFloat, side: CGFloat, reach: CGFloat = 1.62) -> NSBezierPath {
    let r = side / 2
    let c = NSPoint(x: x + r, y: y + r)
    let theta: CGFloat = commaAngle * .pi / 180
    let L = r * reach                            // tip distance from bowl centre
    let alpha = acos(min(0.999, r / L))          // half-angle subtended by the tangents
    let tip = NSPoint(x: c.x + L * cos(theta), y: c.y + L * sin(theta))

    let a = theta + alpha, b = theta - alpha
    let path = NSBezierPath()
    path.move(to: NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
    // The arc on the far side from the tip: everything the tangents don't cover.
    path.appendArc(withCenter: c, radius: r,
                   startAngle: a * 180 / .pi,
                   endAngle: (b + 2 * .pi) * 180 / .pi, clockwise: false)
    path.line(to: tip)
    path.close()
    return path
}

/// One quotation stroke: a circle with the bottom-left corner squared off into a tail.
/// Mirrors the brand doc's `border-radius: 50% 50% 50% <tail>`.
func strokePath(x: CGFloat, y: CGFloat, side: CGFloat, tail: CGFloat) -> NSBezierPath {
    let r = side / 2
    let center = NSPoint(x: x + r, y: y + r)
    let path = NSBezierPath()
    // Small squared corner at bottom-left, then three quarters of the circle.
    path.appendArc(withCenter: NSPoint(x: x + tail, y: y + tail),
                   radius: tail, startAngle: 180, endAngle: 270, clockwise: false)
    path.appendArc(withCenter: center, radius: r,
                   startAngle: -90, endAngle: 180, clockwise: false)
    path.close()
    return path
}

func render(size: CGFloat, variant: Variant) -> NSBitmapImageRep {
    let px = Int(size.rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate \(px)×\(px) bitmap") }

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    let body = size * bodyRatio
    let inset = (size - body) / 2
    let bodyRect = NSRect(x: inset, y: inset, width: body, height: body)

    variant.ground.setFill()
    squirclePath(in: bodyRect, n: squircleExponent).fill()

    let blob = body * blobRatio
    let gap = body * gapRatio
    let tail = blob * tailFraction
    let markWidth = blob * 2 + gap
    let x0 = bodyRect.minX + (body - markWidth) / 2
    let y0 = bodyRect.minY + (body - blob) / 2

    func stroke(at sx: CGFloat) -> NSBezierPath {
        shape == "comma"
            ? commaPath(x: sx, y: y0, side: blob, reach: commaReach)
            : strokePath(x: sx, y: y0, side: blob, tail: tail)
    }
    variant.voiceA.setFill()
    stroke(at: x0).fill()
    variant.voiceB.setFill()
    stroke(at: x0 + blob + gap).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - CLI
var out = "icon.png"
var size: CGFloat = 1024
var variantName = "violet"

var args = Array(CommandLine.arguments.dropFirst())
var positional: [String] = []
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--size":    size = CGFloat(Double(args.removeFirst()) ?? 1024)
    case "--variant": variantName = args.removeFirst()
    case "--tail":    tailFraction = CGFloat(Double(args.removeFirst()) ?? 0.104)
    case "--gap":     gapRatio = CGFloat(Double(args.removeFirst()) ?? 0.068)
    case "--shape":   shape = args.removeFirst()
    case "--reach":   commaReach = CGFloat(Double(args.removeFirst()) ?? 1.62)
    case "--angle":   commaAngle = CGFloat(Double(args.removeFirst()) ?? 225)
    default:          positional.append(arg)
    }
}
if let first = positional.first { out = first }

guard let variant = variants[variantName] else {
    FileHandle.standardError.write(Data("unknown variant '\(variantName)'\n".utf8))
    exit(1)
}
guard let png = render(size: size, variant: variant).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) — \(Int(size))px \(variantName)")
