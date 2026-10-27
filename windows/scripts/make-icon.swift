// Draws Araso's Windows icon: the macOS menu-bar mark (A, 아 and あ cut into rows, one per
// language; scripts/make-icon.swift) in white on a rounded blue square, since Windows shows
// icons as drawn, on a light or a dark taskbar alike. Writes an .ico with PNG images at the sizes
// Windows asks for. --slash strikes it through, for the pause indicator. Given a folder instead of
// an .ico, writes the PNGs Linux's icon theme takes (<folder>/<size>/araso.png, araso-paused.png
// with --slash; linux/data/icons).
// usage: swift windows/scripts/make-icon.swift [--slash] <out.ico | folder>
import AppKit
import CoreText

let out = URL(fileURLWithPath: CommandLine.arguments.last!)
let slashed = CommandLine.arguments.contains("--slash")
let sizes = [16, 20, 24, 32, 40, 48, 64, 256]

func roundedFont(_ size: CGFloat) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
}

/// Outline of `text` centred on (cx, cy) in a box of height `h`, y from the top.
func glyphPath(_ text: String, size: CGFloat, cx: CGFloat, cy: CGFloat, h: CGFloat) -> CGPath {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: roundedFont(size)]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        for i in 0..<count {
            if let g = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                path.addPath(g, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
    }
    let box = path.boundingBoxOfPath
    var move = CGAffineTransform(translationX: cx - box.midX, y: (h - cy) - box.midY)
    return path.copy(using: &move)!
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let c = context.cgContext
    let s = CGFloat(pixels)
    // The badge: a rounded square, inset a little at small sizes so it doesn't touch its neighbours.
    let inset = pixels <= 24 ? 0.5 : s * 0.04
    let badge = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    c.addPath(CGPath(roundedRect: badge, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil))
    c.setFillColor(NSColor(srgbRed: 0.24, green: 0.42, blue: 0.94, alpha: 1).cgColor)
    c.fillPath()

    // The mark, 20×16 on macOS, scaled into the badge.
    let w: CGFloat = 20, h: CGFloat = 16
    let scale = (s * 0.72) / w
    c.saveGState()
    c.translateBy(x: (s - w * scale) / 2, y: (s - h * scale) / 2)
    c.scaleBy(x: scale, y: scale)
    c.setFillColor(NSColor.white.cgColor)
    let letters: [(String, CGFloat)] = [("A", 18), ("아", 17), ("あ", 17)]
    let gap: CGFloat = 1
    for (i, (text, size)) in letters.enumerated() {
        let top = h * CGFloat(i) / 3 + (i == 0 ? 0 : gap / 2)
        let bottom = h * CGFloat(i + 1) / 3 - (i == 2 ? 0 : gap / 2)
        c.saveGState()
        c.clip(to: CGRect(x: 0, y: h - bottom, width: w, height: bottom - top))
        c.addPath(glyphPath(text, size: size, cx: w / 2, cy: h / 2, h: h))
        c.fillPath()
        c.restoreGState()
    }
    if slashed {
        let from = CGPoint(x: 2, y: h - 1), to = CGPoint(x: w - 2, y: 1)
        c.setLineCap(.round)
        c.setStrokeColor(NSColor(srgbRed: 0.24, green: 0.42, blue: 0.94, alpha: 1).cgColor)
        c.setLineWidth(3.2)
        c.move(to: from); c.addLine(to: to); c.strokePath()
        c.setStrokeColor(NSColor.white.cgColor)
        c.setLineWidth(1.4)
        c.move(to: from); c.addLine(to: to); c.strokePath()
    }
    c.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if out.pathExtension != "ico" {
    for size in [16, 22, 24, 32, 48, 64, 128, 256] {
        let folder = out.appendingPathComponent("\(size)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! png(size).write(to: folder.appendingPathComponent(slashed ? "araso-paused.png" : "araso.png"))
    }
    exit(0)
}

// ICONDIR, then one ICONDIRENTRY per image, then the PNGs.
var ico = Data()
func u16(_ v: Int) { var x = UInt16(v).littleEndian; ico.append(Data(bytes: &x, count: 2)) }
func u32(_ v: Int) { var x = UInt32(v).littleEndian; ico.append(Data(bytes: &x, count: 4)) }
let images = sizes.map(png)
u16(0); u16(1); u16(images.count)
var offset = 6 + 16 * images.count
for (size, image) in zip(sizes, images) {
    ico.append(UInt8(size >= 256 ? 0 : size))
    ico.append(UInt8(size >= 256 ? 0 : size))
    ico.append(0); ico.append(0)
    u16(1); u16(32)
    u32(image.count); u32(offset)
    offset += image.count
}
for image in images { ico.append(image) }
try! ico.write(to: out)
