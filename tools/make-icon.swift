// Draws the app icon: swift tools/make-icon.swift iPadDash/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
import AppKit
import CoreGraphics

// 1024 × 1024 opaque app icon: a portrait iPad showing a miniature summary page.
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downward, like UIKit.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    return CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
}

// Background: quiet slate gradient.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.36, 0.43, 0.52), rgb(0.17, 0.21, 0.27)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])

// The iPad: dark body with a soft shadow, a screen, and a home button.
let body = CGRect(x: 232, y: 112, width: 560, height: 800)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: rgb(0, 0, 0, 0.45))
fill(rounded(body, 64), rgb(0.10, 0.11, 0.13))
ctx.restoreGState()
fill(rounded(body.insetBy(dx: 3, dy: 3), 61), rgb(0.16, 0.17, 0.19))   // a hint of an edge
fill(rounded(body.insetBy(dx: 10, dy: 10), 56), rgb(0.08, 0.085, 0.10))
let screen = CGRect(x: body.minX + 38, y: body.minY + 92, width: body.width - 76, height: body.height - 184)
fill(rounded(screen, 6), rgb(0.02, 0.02, 0.025))
let home = CGRect(x: body.midX - 24, y: screen.maxY + 22, width: 48, height: 48)
ctx.addEllipse(in: home); ctx.setStrokeColor(rgb(0.30, 0.31, 0.34)); ctx.setLineWidth(4); ctx.strokePath()
ctx.addEllipse(in: CGRect(x: body.midX - 6, y: body.minY + 44, width: 12, height: 12))
ctx.setFillColor(rgb(0.20, 0.21, 0.24)); ctx.fillPath()

// The dashboard on the screen, as bars for text.
let ink = rgb(0.84, 0.84, 0.84)
let faint = rgb(0.84, 0.84, 0.84, 0.45)
let red = rgb(0.98, 0.33, 0.30)
let x0 = screen.minX + 34, x1 = screen.maxX - 34
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
    fill(rounded(CGRect(x: x, y: y, width: w, height: h), h / 2), c)
}
var y = screen.minY + 34
bar(screen.midX - 60, y, 120, 14, faint)            // SUMMARY
y += 36
bar(screen.midX - 115, y, 230, 30, red)            // "1 red item"
y += 66
bar(x0, y, 150, 18, red); bar(x1 - 70, y, 70, 18, red)          // a red row
y += 36
bar(x0, y, 120, 18, faint); bar(x1 - 90, y, 90, 18, faint)      // a quiet row

// The big clock: four thin rounded digits' worth of bars.
y += 62
let clockY = y
for (i, w) in [CGFloat(52), 52, 52, 52].enumerated() {
    let x = screen.midX - 149 + CGFloat(i) * 70 + (i >= 2 ? 36 : 0)
    ctx.addPath(rounded(CGRect(x: x, y: clockY, width: w, height: 84), 20))
    ctx.setStrokeColor(ink); ctx.setLineWidth(9); ctx.strokePath()
}
ctx.addEllipse(in: CGRect(x: screen.midX - 5, y: clockY + 22, width: 10, height: 10))
ctx.addEllipse(in: CGRect(x: screen.midX - 5, y: clockY + 54, width: 10, height: 10))
ctx.setFillColor(ink); ctx.fillPath()

// Weather: a temperature line from cool blue through neutral to warm orange.
let gTop = clockY + 140, gBottom = gTop + 120
let temps: [CGFloat] = [0.15, 0.30, 0.55, 0.80, 0.95, 0.85, 0.60, 0.40]
let pts = temps.enumerated().map { i, t -> CGPoint in
    CGPoint(x: x0 + 10 + CGFloat(i) * (x1 - x0 - 20) / 7, y: gBottom - t * (gBottom - gTop))
}
let line = CGMutablePath(); line.addLines(between: pts)
let area = line.mutableCopy()!
area.addLine(to: CGPoint(x: pts.last!.x, y: gBottom + 30)); area.addLine(to: CGPoint(x: pts[0].x, y: gBottom + 30))
area.closeSubpath()
let warm = CGGradient(colorsSpace: cs, colors: [rgb(0.80, 0.52, 0.34), rgb(0.82, 0.82, 0.82), rgb(0.40, 0.56, 0.74)] as CFArray,
                      locations: [0, 0.5, 1])!
ctx.saveGState(); ctx.addPath(area); ctx.clip(); ctx.setAlpha(0.22)
ctx.drawLinearGradient(warm, start: CGPoint(x: 0, y: gTop), end: CGPoint(x: 0, y: gBottom + 30), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(line); ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(warm, start: CGPoint(x: 0, y: gTop), end: CGPoint(x: 0, y: gBottom), options: [])
ctx.restoreGState()

// Footer rule and page dots, one of them red.
let footY = screen.maxY - 44
fill(CGPath(rect: CGRect(x: x0, y: footY - 26, width: x1 - x0, height: 3), transform: nil), faint)
for i in 0..<5 {
    let c: CGColor = i == 0 ? ink : (i == 3 ? red : rgb(0.84, 0.84, 0.84, 0.3))
    ctx.addEllipse(in: CGRect(x: screen.midX - 62 + CGFloat(i) * 28, y: footY, width: 13, height: 13))
    ctx.setFillColor(c); ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
