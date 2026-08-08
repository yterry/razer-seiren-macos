// Renders the Seiren app icon (1024x1024 PNG) with CoreGraphics/AppKit.
// Original artwork: a condenser-mic silhouette with a green LED band,
// on a macOS-style dark squircle. No Razer marks, no SF Symbols.
//
// Usage: swift scripts/generate-icon.swift Resources/AppIcon.png
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let S = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// ---- macOS icon-grid squircle -------------------------------------------
let squircleRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: 186, yRadius: 186)

// Everything draws inside the squircle.
squircle.addClip()

// Background: graphite vertical gradient.
NSGradient(starting: color(0x2E343B), ending: color(0x0B0D10))!
    .draw(in: squircleRect, angle: -90)

// Soft green ambience behind the mic, strongest at the LED band.
NSGradient(colors: [color(0x3ED12E, 0.28), color(0x3ED12E, 0.0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 498), radius: 0,
          toCenter: NSPoint(x: 512, y: 498), radius: 430, options: [])

// ---- Mic stand -----------------------------------------------------------
let steel = NSGradient(colors: [color(0x1D2125), color(0x3A4046), color(0x1D2125)])!
let stem = NSBezierPath(roundedRect: NSRect(x: 492, y: 330, width: 40, height: 70),
                        xRadius: 8, yRadius: 8)
steel.draw(in: stem, angle: 0)
let base = NSBezierPath(roundedRect: NSRect(x: 392, y: 288, width: 240, height: 46),
                        xRadius: 23, yRadius: 23)
steel.draw(in: base, angle: 0)

// ---- Mic capsule ---------------------------------------------------------
let capsuleRect = NSRect(x: 372, y: 380, width: 280, height: 420)
let capsule = NSBezierPath(roundedRect: capsuleRect, xRadius: 140, yRadius: 140)

// Cylindrical shading: dark edges, lit center.
NSGradient(colors: [color(0x2B3037), color(0x5B646E), color(0x2B3037)])!
    .draw(in: capsule, angle: 0)

// Grille: dot mesh clipped to the capsule, above the LED band.
NSGraphicsContext.saveGraphicsState()
capsule.addClip()
let dot = color(0x0E1114, 0.85)
dot.setFill()
var row = 0
var y: CGFloat = 544
while y <= 786 {
    let offset: CGFloat = (row % 2 == 0) ? 0 : 15
    var x: CGFloat = 384 + offset
    while x <= 648 {
        NSBezierPath(ovalIn: NSRect(x: x - 6.5, y: y - 6.5, width: 13, height: 13)).fill()
        x += 30
    }
    y += 26
    row += 1
}
// Specular highlight along the upper-left of the capsule.
NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0.0)])!
    .draw(in: NSBezierPath(rect: NSRect(x: 372, y: 640, width: 280, height: 160)), angle: -90)

// LED band: bright green with a glow, ends following the capsule curve.
let band = NSRect(x: 372, y: 480, width: 280, height: 26)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x3ED12E, 0.9)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = .zero
shadow.set()
color(0x3ED12E).setFill()
NSBezierPath(rect: band).fill()
NSGraphicsContext.restoreGraphicsState()
// Hot core line inside the band.
color(0xB8F5A8, 0.9).setFill()
NSBezierPath(rect: NSRect(x: 372, y: 489, width: 280, height: 7)).fill()
NSGraphicsContext.restoreGraphicsState() // capsule clip

// Edge stroke so the capsule separates from the background at small sizes.
color(0x0A0C0E, 0.65).setStroke()
capsule.lineWidth = 4
capsule.stroke()

// Subtle rim light on the squircle edge.
color(0xFFFFFF, 0.06).setStroke()
let rim = NSBezierPath(roundedRect: squircleRect.insetBy(dx: 1.5, dy: 1.5),
                       xRadius: 184, yRadius: 184)
rim.lineWidth = 3
rim.stroke()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
