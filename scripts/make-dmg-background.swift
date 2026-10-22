// make-dmg-background.swift: renders the release disk image's window background (an arrow from
// the app to the Applications link, and a caption) with CoreGraphics. `make dmg-background` runs
// it into Resources/; scripts/dmg-settings.py places the icons over it.
//
//   swift scripts/make-dmg-background.swift <outdir>
//
// Writes <outdir>/dmg-background.png (600x380) and dmg-background@2x.png; dmgbuild combines the
// two into a HiDPI TIFF. Light, because Finder draws the icon labels in black. The icon centers
// below must match `icon_locations` in scripts/dmg-settings.py.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = CGSize(width: 600, height: 380)
let appCenter = CGPoint(x: 150, y: 170)   // y-down, points
let linkCenter = CGPoint(x: 450, y: 170)
let iconSize: CGFloat = 128

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ ctx: CGContext) {
    // Background: a soft vertical gradient.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [color(0xFAFAFC), color(0xE9EAEF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // Arrow: a dotted arc between the two icons, then a gap and a rounded head.
    let start = CGPoint(x: appCenter.x + iconSize / 2 + 22, y: appCenter.y)
    let tip = CGPoint(x: linkCenter.x - iconSize / 2 - 26, y: linkCenter.y)
    let end = CGPoint(x: tip.x - 20, y: tip.y - 3)
    let control = CGPoint(x: (start.x + end.x) / 2, y: appCenter.y - 34)
    let arc = CGMutablePath()
    arc.move(to: start)
    arc.addQuadCurve(to: end, control: control)
    ctx.setStrokeColor(color(0x8A8F99))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(arc)
    ctx.setLineDash(phase: 0, lengths: [0.1, 13])
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Head, pointing from the end of the arc to the tip.
    let angle = atan2(tip.y - end.y, tip.x - end.x)
    let head = CGMutablePath()
    for side in [-1.0, 1.0] {
        let a = angle + .pi - side * 0.6
        head.move(to: CGPoint(x: tip.x + 15 * cos(a), y: tip.y + 15 * sin(a)))
        head.addLine(to: tip)
    }
    ctx.addPath(head)
    ctx.strokePath()

    // Caption, centered near the bottom.
    let font = CTFontCreateUIFontForLanguage(.system, 13, nil)!
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0x6E7380),
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "Drag ClaudeTray to Applications to install", attributes: attrs))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    // CoreText draws y-up: flip around the baseline.
    ctx.translateBy(x: (size.width - width) / 2, y: 318)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func render(scale: Int) -> CGImage {
    let w = Int(size.width) * scale, h = Int(size.height) * scale
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, dpi: Int, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let props = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(dest, img, props)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-dmg-background <outdir>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
writePNG(render(scale: 1), dpi: 72, out.appendingPathComponent("dmg-background.png"))
writePNG(render(scale: 2), dpi: 144, out.appendingPathComponent("dmg-background@2x.png"))
print("wrote \(out.path)/dmg-background{,@2x}.png")
