import AppKit
import SwiftUI

/// Colors taken from the current artwork: a vivid accent that reads well on the dark theme.
struct ArtworkPalette: Equatable, Sendable {
    var accent: Color
    /// Text/icon color on top of `accent`.
    var onAccent: Color
    /// A darker shade for glows and gradients.
    var deep: Color
    var isDefault = false

    static let `default` = ArtworkPalette(accent: Theme.accent, onAccent: Theme.accentInk, deep: Color(hex: 0x2B3A0F), isDefault: true)

    /// Picks the most prominent saturated hue (24 hue buckets weighted by saturation × brightness),
    /// then lifts it so it stays visible on dark backgrounds. Grayscale art falls back to the brand accent.
    static func extract(from image: NSImage) -> ArtworkPalette {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return .default }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var weights = [Double](repeating: 0, count: 24)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: 24)
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard brightness > 0.18, saturation > 0.22 else { continue }
                let weight = Double(saturation * saturation) * Double(0.4 + brightness)
                let bucket = min(23, Int(hue * 24))
                weights[bucket] += weight
                sums[bucket].r += Double(color.redComponent) * weight
                sums[bucket].g += Double(color.greenComponent) * weight
                sums[bucket].b += Double(color.blueComponent) * weight
            }
        }
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0.6 else { return .default }
        let w = weights[best]
        let base = NSColor(deviceRed: sums[best].r / w, green: sums[best].g / w, blue: sums[best].b / w, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let accent = NSColor(deviceHue: hue, saturation: max(0.45, min(saturation, 0.9)), brightness: max(0.78, brightness), alpha: 1)
        let deep = NSColor(deviceHue: hue, saturation: max(0.5, saturation), brightness: 0.24, alpha: 1)
        let luminance = 0.2126 * accent.redComponent + 0.7152 * accent.greenComponent + 0.0722 * accent.blueComponent
        return ArtworkPalette(accent: Color(nsColor: accent), onAccent: luminance > 0.55 ? Color(hex: 0x111214) : .white,
                              deep: Color(nsColor: deep))
    }
}
