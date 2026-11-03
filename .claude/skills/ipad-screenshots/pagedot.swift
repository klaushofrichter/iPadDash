// Prints which page dot is lit in an iPadDash screenshot (1-based), or 0 if
// none stands out (another app, About sheet, mid-fade).
// Dot centers are for the iPad Air's 1536 x 2048 portrait screenshots.
import Foundation
import CoreGraphics
import ImageIO

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let src = CGImageSourceCreateWithURL(url, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

// The dots sit 88 px higher while the no-network banner is showing.
let xs = [693, 743, 793, 843], ys = [2012, 1924]
guard w == 1536, h == 2048 else { print(0); exit(0) }
for y in ys {
    let lum = xs.map { x -> Int in
        let i = (y * w + x) * 4
        return Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])
    }
    let sorted = lum.sorted()
    // The lit dot is far brighter (dark theme) or darker (light theme) than the others.
    if sorted[3] - sorted[2] > 150 { print(lum.firstIndex(of: sorted[3])! + 1); exit(0) }
    if sorted[1] - sorted[0] > 150 { print(lum.firstIndex(of: sorted[0])! + 1); exit(0) }
}
print(0)
