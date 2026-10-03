// Renders release artwork: the DMG window background and the README banner.
//
//   swift scripts/render_art.swift <output-dir>
//
// Produces dmg-background.png (660×420), dmg-background@2x.png and banner.png (1280×440 @2x).
import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/art")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for font in ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "JetBrainsMono-Regular", "JetBrainsMono-Medium"] {
    let url = root.appendingPathComponent("Soundflow/Resources/Fonts/\(font).ttf")
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let accent = color(0xC2F25B), ink = color(0x12160A), bg = color(0x0D0E11)
let appIcon = NSImage(contentsOf: root.appendingPathComponent("Soundflow/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"))!

/// Renders `draw` into a PNG of `size` points at `scale`; the context is flipped (origin top-left).
func render(_ name: String, size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

func text(_ string: String, _ font: String, _ size: CGFloat, _ fill: NSColor, centerX: CGFloat? = nil, x: CGFloat = 0, y: CGFloat, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: font, size: size)!, .foregroundColor: fill, .kern: tracking]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let width = attributed.size().width
    // The context is flipped, so draw text in an unflipped local frame.
    NSGraphicsContext.current!.cgContext.saveGState()
    let cg = NSGraphicsContext.current!.cgContext
    let originX = centerX.map { $0 - width / 2 } ?? x
    cg.translateBy(x: originX, y: y + size)
    cg.scaleBy(x: 1, y: -1)
    attributed.draw(at: .zero)
    cg.restoreGState()
}

/// A sound wave travelling from `start` to `end`: amplitude swells in the middle and calms at both ends.
func wavePath(from start: CGPoint, to end: CGPoint, amplitude: CGFloat, cycles: CGFloat, lift: CGFloat) -> CGMutablePath {
    let path = CGMutablePath()
    let steps = 240
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let envelope = pow(sin(.pi * t), 1.6)
        let x = start.x + (end.x - start.x) * t
        let arc = -lift * sin(.pi * t)
        let y = start.y + (end.y - start.y) * t + arc + sin(2 * .pi * cycles * t) * amplitude * envelope
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    return path
}

func radialGlow(_ cg: CGContext, center: CGPoint, radius: CGFloat, color glow: NSColor) {
    let colors = [glow.cgColor, glow.withAlphaComponent(0).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// MARK: - DMG background (660×420; Finder places the app at (170,180) and Applications at (490,180))

func drawDMG(_ cg: CGContext) {
    let size = CGSize(width: 660, height: 420)
    cg.setFillColor(color(0xF4F6EF).cgColor)
    cg.fill(CGRect(origin: .zero, size: size))
    radialGlow(cg, center: CGPoint(x: 330, y: 170), radius: 330, color: accent.withAlphaComponent(0.55))
    radialGlow(cg, center: CGPoint(x: 170, y: 180), radius: 120, color: color(0xFFFFFF, 0.55))

    // Dotted grid, fading towards the edges.
    for gx in stride(from: CGFloat(18), to: size.width, by: 22) {
        for gy in stride(from: CGFloat(18), to: size.height, by: 22) {
            let d = hypot(gx - 330, gy - 190) / 380
            cg.setFillColor(ink.withAlphaComponent(0.10 * max(0, 1 - d)).cgColor)
            cg.fillEllipse(in: CGRect(x: gx - 0.9, y: gy - 0.9, width: 1.8, height: 1.8))
        }
    }

    // Echo waves behind the main one.
    for (index, alpha) in [(0, 0.10), (1, 0.16)] {
        let offset = CGFloat(index + 1) * 9
        let echo = wavePath(from: CGPoint(x: 250, y: 172 + offset), to: CGPoint(x: 406, y: 172 + offset), amplitude: 7, cycles: 3.5, lift: 18)
        cg.addPath(echo)
        cg.setStrokeColor(ink.withAlphaComponent(alpha).cgColor)
        cg.setLineWidth(1.4)
        cg.setLineCap(.round)
        cg.strokePath()
    }

    // The main wave → arrow.
    let start = CGPoint(x: 250, y: 172), end = CGPoint(x: 404, y: 172)
    cg.addPath(wavePath(from: start, to: end, amplitude: 11, cycles: 3.5, lift: 22))
    cg.setStrokeColor(ink.cgColor)
    cg.setLineWidth(4)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.strokePath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: end.x - 13, y: end.y - 11))
    head.addLine(to: CGPoint(x: end.x + 2, y: end.y))
    head.addLine(to: CGPoint(x: end.x - 13, y: end.y + 11))
    cg.addPath(head)
    cg.strokePath()

    text("Перетащите Soundflow в «Программы»", "Inter-SemiBold", 19, ink, centerX: 330, y: 318)
    text("громкость и выход — для каждого приложения", "JetBrainsMono-Regular", 11, color(0x12160A, 0.55), centerX: 330, y: 352, tracking: 0.3)
}

render("dmg-background.png", size: CGSize(width: 660, height: 420), scale: 1, draw: drawDMG)
render("dmg-background@2x.png", size: CGSize(width: 660, height: 420), scale: 2, draw: drawDMG)

// MARK: - README banner (dark, app style)

render("banner.png", size: CGSize(width: 1280, height: 440), scale: 2) { cg in
    let size = CGSize(width: 1280, height: 440)
    cg.setFillColor(bg.cgColor)
    cg.fill(CGRect(origin: .zero, size: size))
    radialGlow(cg, center: CGPoint(x: 330, y: 220), radius: 420, color: accent.withAlphaComponent(0.16))
    radialGlow(cg, center: CGPoint(x: 1100, y: 380), radius: 380, color: accent.withAlphaComponent(0.06))

    // Faint waveform field across the banner.
    for row in 0..<7 {
        let y = 70 + CGFloat(row) * 50
        let path = wavePath(from: CGPoint(x: -20, y: y), to: CGPoint(x: 1300, y: y), amplitude: 10 + CGFloat(row % 3) * 5,
                            cycles: 9 + CGFloat(row), lift: 0)
        cg.addPath(path)
        cg.setStrokeColor(accent.withAlphaComponent(0.035 + 0.012 * CGFloat(row % 3)).cgColor)
        cg.setLineWidth(1.5)
        cg.strokePath()
    }

    // Accent wave under the title.
    cg.addPath(wavePath(from: CGPoint(x: 470, y: 312), to: CGPoint(x: 1150, y: 312), amplitude: 9, cycles: 12, lift: 0))
    cg.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
    cg.setLineWidth(3)
    cg.setLineCap(.round)
    cg.strokePath()

    // App icon with a soft shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 50, color: accent.withAlphaComponent(0.25).cgColor)
    NSGraphicsContext.current!.cgContext.saveGState()
    cg.translateBy(x: 120, y: 330)
    cg.scaleBy(x: 1, y: -1)
    appIcon.draw(in: CGRect(x: 0, y: 0, width: 260, height: 260))
    cg.restoreGState()
    cg.restoreGState()

    text("Soundflow", "Inter-SemiBold", 84, color(0xF1F2F4), x: 466, y: 128, tracking: -2)
    text("Громкость и выход звука для каждого приложения на macOS", "Inter-Regular", 24, color(0x9AA0AB), x: 470, y: 238)
    text("macOS 14.2+  ·  Core Audio Process Taps  ·  без драйверов", "JetBrainsMono-Regular", 15, color(0x5F6571), x: 470, y: 352, tracking: 0.3)
}

print("Artwork → \(output.path)")
