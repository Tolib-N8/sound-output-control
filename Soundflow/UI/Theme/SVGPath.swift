import SwiftUI

/// Minimal SVG path-data parser (M L H V C S Q T A Z, absolute and relative) producing a SwiftUI `Path`.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var scanner = Scanner(bytes: Array(data.utf8))
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: UInt8 = 0

        while true {
            if let next = scanner.command() {
                command = next
            } else if scanner.atEnd || command == 0 {
                break
            }
            let relative = command >= 97 // lowercase
            let origin = relative ? current : .zero
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x, y: origin.y + y) }

            switch command | 0x20 { // lowercase
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L") // further pairs are line-tos
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: point(x1, y1), control2: c2)
                lastCubicControl = c2; lastQuadControl = nil
            case UInt8(ascii: "s"):
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2; lastQuadControl = nil
            case UInt8(ascii: "q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let control = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control; lastCubicControl = nil
            case UInt8(ascii: "t"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let control = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = point(x, y)
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control; lastCubicControl = nil
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = point(x, y)
                addArc(to: &path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
                lastCubicControl = nil; lastQuadControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil
                command = 0 // Z takes no arguments; a new command must follow
            default:
                return path
            }
        }
        return path
    }

    /// Converts an SVG endpoint arc to cubic Béziers (SVG 1.1, appendix F.6).
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }

        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator == 0 ? 0 : (max(0, numerator / denominator)).squareRoot()
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1 / ry
        let cyp = coefficient * -ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func pointAt(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                    y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                    y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        for index in 0..<segments {
            let a1 = theta1 + CGFloat(index) * step, a2 = a1 + step
            let start = pointAt(a1), end = index == segments - 1 ? p1 : pointAt(a2)
            let d1 = derivative(a1), d2 = derivative(a2)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + k * d1.x, y: start.y + k * d1.y),
                          control2: CGPoint(x: end.x - k * d2.x, y: end.y - k * d2.y))
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool {
            mutating get { skipSeparators(); return index >= bytes.count }
        }

        mutating func skipSeparators() {
            while index < bytes.count, [0x20, 0x2C, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            let isLetter = (65...90).contains(byte) || (97...122).contains(byte)
            guard isLetter, byte != UInt8(ascii: "e"), byte != UInt8(ascii: "E") else { return nil }
            index += 1
            return byte
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var digits = 0
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else { index = start; return nil }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                var lookahead = index + 1
                if lookahead < bytes.count, bytes[lookahead] == UInt8(ascii: "-") || bytes[lookahead] == UInt8(ascii: "+") { lookahead += 1 }
                if lookahead < bytes.count, (48...57).contains(bytes[lookahead]) {
                    index = lookahead
                    while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                }
            }
            return Double(String(decoding: bytes[start..<index], as: UTF8.self)).map { CGFloat($0) }
        }

        /// Arc flags are single characters and may be written without separators ("0 0118 8").
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { return nil }
            index += 1
            return bytes[index - 1] == UInt8(ascii: "1")
        }
    }
}
