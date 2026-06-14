import AppKit
import Foundation

// Renders a 1024×1024 app icon: a white waveform on a purple gradient rounded square.
// Usage: swift GenerateIcon.swift <output.png>

let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()

// Rounded-rect background with a vertical gradient.
let inset: CGFloat = 64
let bgRect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 200, yRadius: 200)
bg.addClip()
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.46, green: 0.31, blue: 0.96, alpha: 1),
    ending: NSColor(calibratedRed: 0.29, green: 0.16, blue: 0.80, alpha: 1)
)!
gradient.draw(in: NSRect(x: 0, y: 0, width: S, height: S), angle: -90)

// Symmetric waveform of rounded vertical bars.
let heights: [CGFloat] = [0.30, 0.50, 0.72, 0.92, 1.0, 0.78, 0.52, 0.78, 1.0, 0.92, 0.72, 0.50, 0.30]
let n = heights.count
let barW: CGFloat = 34
let gap: CGFloat = 24
let totalW = CGFloat(n) * barW + CGFloat(n - 1) * gap
var x = (S - totalW) / 2
let maxH: CGFloat = 440
NSColor.white.setFill()
for h in heights {
    let bh = max(barW, maxH * h)
    let bar = NSBezierPath(
        roundedRect: NSRect(x: x, y: (S - bh) / 2, width: barW, height: bh),
        xRadius: barW / 2, yRadius: barW / 2
    )
    bar.fill()
    x += barW + gap
}

image.unlockFocus()

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { FileHandle.standardError.write(Data("failed to render icon\n".utf8)); exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
