import CoreGraphics
import Foundation

/// Pose of one icon part at a moment of its animation, in the icon's 24×24 coordinate space.
struct PartPose {
    var transform: CGAffineTransform = .identity
    var opacity: Double = 1
    var trim: ClosedRange<Double> = 0...1

    init(_ transform: CGAffineTransform = .identity, opacity: Double = 1, trim: ClosedRange<Double> = 0...1) {
        self.transform = transform
        self.opacity = opacity
        self.trim = trim
    }
}

/// An icon's press animation. `t` runs 0 → 1; every motion returns to the resting pose at `t == 1`.
struct IconMotion: Sendable {
    var duration: Double
    var part: (@Sendable (_ index: Int, _ t: Double) -> PartPose)?
    var whole: (@Sendable (_ t: Double) -> PartPose)?

    init(_ duration: Double, part: (@Sendable (Int, Double) -> PartPose)? = nil, whole: (@Sendable (Double) -> PartPose)? = nil) {
        self.duration = duration
        self.part = part
        self.whole = whole
    }
}

// MARK: - Motion math

private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
/// Local progress of `t` within [a, b].
private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
private func easeOut(_ t: Double) -> Double { 1 - pow(1 - clamp(t), 3) }
private func easeIn(_ t: Double) -> Double { pow(clamp(t), 3) }
private func easeInOut(_ t: Double) -> Double {
    let t = clamp(t)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}
/// Overshoots past 1 and settles.
private func backOut(_ t: Double, _ s: Double = 1.7) -> Double {
    let x = clamp(t) - 1
    return 1 + (s + 1) * x * x * x + s * x * x
}
/// 0 → 1 → 0.
private func bump(_ t: Double) -> Double { sin(.pi * clamp(t)) }
/// Decaying oscillation, 0 at both ends.
private func wobble(_ t: Double, _ cycles: Double) -> Double { sin(2 * .pi * cycles * clamp(t)) * (1 - clamp(t)) }

private func rotate(_ degrees: Double, _ x: Double = 12, _ y: Double = 12) -> CGAffineTransform {
    CGAffineTransform(translationX: x, y: y).rotated(by: degrees * .pi / 180).translatedBy(x: -x, y: -y)
}
private func scale(_ sx: Double, _ sy: Double? = nil, _ x: Double = 12, _ y: Double = 12) -> CGAffineTransform {
    CGAffineTransform(translationX: x, y: y).scaledBy(x: sx, y: sy ?? sx).translatedBy(x: -x, y: -y)
}
private func move(_ dx: Double, _ dy: Double) -> CGAffineTransform { CGAffineTransform(translationX: dx, y: dy) }
private func draw(_ progress: Double) -> ClosedRange<Double> { 0...max(0.001, clamp(progress)) }

/// Leaves along a direction and re-enters from the opposite side.
private func passThrough(_ t: Double, dx: Double, dy: Double) -> PartPose {
    if t < 0.45 {
        let p = easeIn(t / 0.45)
        return PartPose(move(dx * p, dy * p), opacity: 1 - p)
    }
    let p = easeOut((t - 0.45) / 0.55)
    return PartPose(move(-dx * (1 - p), -dy * (1 - p)), opacity: p)
}

// MARK: - Catalogue

enum IconMotions {
    static func motion(for name: String) -> IconMotion {
        switch name {

        // Brand / sound
        case "audio-waveform":
            return IconMotion(0.9, part: { _, t in
                PartPose(scale(1, 1 + 0.25 * wobble(t, 2)), trim: draw(easeOut(seg(t, 0, 0.75))))
            })
        case "audio-lines":
            return IconMotion(1.0, part: { i, t in
                let x = 2 + Double(i) * 4
                return PartPose(scale(1, 1 + 0.7 * sin(2 * .pi * (2 * t + Double(i) * 0.17)) * bump(t), x, 11.5))
            })
        case "volume":
            return IconMotion(0.5, whole: { t in
                PartPose(scale(1 + 0.18 * bump(t), nil, 6, 12).concatenating(rotate(6 * wobble(t, 2), 6, 12)))
            })
        case "volume-1", "volume-2":
            return IconMotion(0.7, part: { i, t in
                if i == 0 { return PartPose(scale(1 + 0.12 * bump(seg(t, 0, 0.5)), nil, 6, 12)) }
                let local = seg(t, 0.1 + 0.15 * Double(i - 1), 0.6 + 0.15 * Double(i - 1))
                return PartPose(move(2.5 * bump(local), 0), opacity: 1 - 0.7 * bump(local))
            })
        case "volume-x":
            return IconMotion(0.55, part: { i, t in
                if i == 0 { return PartPose(rotate(8 * wobble(t, 3), 7, 12)) }
                return PartPose(rotate(180 * easeInOut(t), 19, 12).concatenating(scale(1 + 0.35 * bump(t), nil, 19, 12)))
            })
        case "volume-off":
            return IconMotion(0.6, part: { i, t in
                if i == 2 { return PartPose(trim: draw(easeOut(seg(t, 0, 0.6)))) }
                return PartPose(move(0.8 * wobble(t, 3), 0), opacity: 1 - 0.5 * bump(t))
            })
        case "speaker":
            return IconMotion(0.7, part: { i, t in
                switch i {
                case 2, 3: PartPose(scale(1 + 0.15 * wobble(t, 3), nil, 12, 14))
                case 1: PartPose(scale(1 + 0.8 * bump(seg(t, 0, 0.4)), nil, 12, 6))
                default: PartPose()
                }
            })
        case "mic":
            return IconMotion(0.6, part: { i, t in
                switch i {
                case 2: PartPose(scale(1 + 0.12 * wobble(t, 3), nil, 12, 8))
                case 1: PartPose(opacity: 1 - 0.5 * bump(t))
                default: PartPose()
                }
            })
        case "music":
            return IconMotion(0.7, part: { i, t in
                switch i {
                case 1: PartPose(move(0, -2.5 * bump(seg(t, 0, 0.5))))
                case 2: PartPose(move(0, -2.5 * bump(seg(t, 0.2, 0.7))))
                default: PartPose(rotate(5 * wobble(t, 1.5), 15, 10))
                }
            })
        case "radio":
            return IconMotion(0.8, part: { i, t in
                switch i {
                case 4: return PartPose(scale(1 + 0.4 * bump(seg(t, 0, 0.4))))
                case 0, 3:
                    let local = seg(t, 0.1, 0.6)
                    return PartPose(scale(1 + 0.25 * bump(local)), opacity: 1 - 0.6 * bump(local))
                default:
                    let local = seg(t, 0.3, 0.8)
                    return PartPose(scale(1 + 0.15 * bump(local)), opacity: 1 - 0.6 * bump(local))
                }
            })
        case "bell":
            return IconMotion(0.9, part: { i, t in
                i == 0 ? PartPose(rotate(24 * wobble(seg(t, 0.06, 1), 2.5), 12, 3)) : PartPose(rotate(16 * wobble(t, 2.5), 12, 3))
            })
        case "bell-off":
            return IconMotion(0.7, part: { i, t in
                i == 2 ? PartPose(trim: draw(easeOut(seg(t, 0, 0.5)))) : PartPose(rotate(10 * wobble(t, 2), 12, 3))
            })

        // Devices
        case "laptop":
            return IconMotion(0.6, part: { i, t in
                i == 0 ? PartPose(scale(1, 0.2 + 0.8 * backOut(seg(t, 0, 0.8)), 12, 16))
                       : PartPose(scale(1 + 0.1 * bump(t), 1, 12, 16))
            })
        case "headphones":
            return IconMotion(0.7, whole: { t in
                let hop = abs(sin(2 * .pi * t)) * (1 - t)
                return PartPose(move(0, -2.5 * hop).concatenating(rotate(7 * wobble(t, 1.5), 12, 20)))
            })
        case "monitor":
            return IconMotion(0.6, part: { i, t in
                guard i == 0 else { return PartPose() }
                let flicker = 0.6 * bump(seg(t, 0, 0.25)) + 0.4 * bump(seg(t, 0.35, 0.6))
                return PartPose(scale(1 + 0.08 * bump(t), nil, 12, 10), opacity: 1 - flicker)
            })
        case "tv":
            return IconMotion(0.8, part: { i, t in
                i == 0 ? PartPose(rotate(22 * wobble(t, 2.5), 12, 7))
                       : PartPose(scale(1 + 0.06 * bump(t)).concatenating(move(0, -0.8 * bump(t))))
            })
        case "git-merge":
            return IconMotion(0.8, part: { i, t in
                switch i {
                case 2: PartPose(trim: draw(easeOut(seg(t, 0, 0.6))))
                case 1: PartPose(scale(1 + 0.4 * bump(seg(t, 0, 0.4)), nil, 6, 6))
                default: PartPose(scale(1 + 0.4 * bump(seg(t, 0.45, 0.9)), nil, 18, 18))
                }
            })
        case "bluetooth":
            return IconMotion(0.75, part: { _, t in
                PartPose(scale(1 + 0.1 * bump(t)), trim: draw(easeInOut(seg(t, 0, 0.75))))
            })
        case "bluetooth-off":
            return IconMotion(0.6, part: { i, t in
                i == 1 ? PartPose(trim: draw(easeOut(seg(t, 0, 0.55))))
                       : PartPose(move(0.6 * wobble(t, 3), 0), opacity: 1 - 0.5 * bump(t))
            })
        case "battery-full", "battery-medium":
            let order: [Int: (k: Double, x: Double)] = name == "battery-full"
                ? [3: (0, 6), 0: (1, 10), 1: (2, 14)]
                : [2: (0, 6), 0: (1, 10)]
            let terminal = name == "battery-full" ? 2 : 1
            return IconMotion(0.9, part: { i, t in
                if let bar = order[i] {
                    let local = seg(t, 0.1 + 0.18 * bar.k, 0.4 + 0.18 * bar.k)
                    return PartPose(scale(1, max(0.01, easeOut(local)), bar.x, 12), opacity: local > 0 ? 1 : 0)
                }
                if i == terminal { return PartPose(opacity: 1 - 0.7 * bump(seg(t, 0.7, 1))) }
                return PartPose()
            })
        case "plug":
            return IconMotion(0.6, part: { i, t in
                i == 0 ? PartPose() : PartPose(move(0, -2.5 * bump(seg(t, 0, 0.45))))
            })
        case "unplug":
            return IconMotion(0.6, part: { i, t in
                let d = 1.6 * bump(t)
                return [0, 5].contains(i) ? PartPose(move(d, -d)) : PartPose(move(-d, d))
            })
        case "cpu":
            return IconMotion(0.8, part: { i, t in
                switch i {
                case 13: return PartPose(scale(1 + 0.3 * bump(t)))
                case 12: return PartPose()
                default:
                    let local = seg(t, 0.04 * Double(i), 0.3 + 0.04 * Double(i))
                    return PartPose(opacity: 1 - 0.75 * bump(local))
                }
            })
        case "keyboard":
            return IconMotion(0.7, part: { i, t in
                switch i {
                case 8: return PartPose()
                case 6: return PartPose(scale(1 - 0.2 * bump(seg(t, 0.5, 0.9)), 1, 12, 16))
                default:
                    let k = Double(i)
                    let local = seg(t, 0.06 * k, 0.25 + 0.06 * k)
                    return PartPose(move(0, 0.8 * bump(local)), opacity: 1 - 0.5 * bump(local))
                }
            })

        // States
        case "circle-check":
            return IconMotion(0.6, part: { i, t in
                i == 0 ? PartPose(scale(1 + 0.12 * bump(seg(t, 0, 0.5))))
                       : PartPose(trim: draw(easeOut(seg(t, 0.15, 0.75))))
            })
        case "circle-alert":
            return IconMotion(0.6, part: { i, t in
                i == 0 ? PartPose(scale(1 + 0.1 * bump(t))) : PartPose(move(1.2 * wobble(t, 3), 0))
            })
        case "triangle-alert":
            return IconMotion(0.6, part: { i, t in
                let shake = rotate(7 * wobble(t, 3), 12, 21)
                return i == 0 ? PartPose(shake) : PartPose(move(0, -1.2 * bump(seg(t, 0, 0.5))).concatenating(shake))
            })
        case "shield":
            return IconMotion(0.5, whole: { t in PartPose(scale(1 + 0.15 * bump(t))) })
        case "shield-check":
            return IconMotion(0.65, part: { i, t in
                i == 0 ? PartPose(scale(1 + 0.12 * bump(t))) : PartPose(trim: draw(easeOut(seg(t, 0.15, 0.8))))
            })
        case "shield-alert":
            return IconMotion(0.6, part: { i, t in
                let shake = rotate(6 * wobble(t, 3), 12, 22)
                return i == 0 ? PartPose(shake) : PartPose(scale(1 + 0.3 * bump(t)).concatenating(shake))
            })
        case "info":
            return IconMotion(0.5, part: { i, t in
                switch i {
                case 2: PartPose(move(0, -2.5 * bump(seg(t, 0, 0.5))))
                case 1: PartPose(scale(1, 1 + 0.3 * bump(seg(t, 0.2, 0.7)), 12, 16))
                default: PartPose()
                }
            })
        case "zap":
            return IconMotion(0.6, whole: { t in
                let flicker = 0.7 * bump(seg(t, 0, 0.15)) + 0.6 * bump(seg(t, 0.25, 0.4))
                return PartPose(scale(1 + 0.2 * bump(seg(t, 0.3, 0.8))).concatenating(move(0, bump(t))), opacity: 1 - flicker)
            })
        case "rotate-ccw":
            return IconMotion(0.7, whole: { t in PartPose(rotate(-360 * easeInOut(t))) })
        case "refresh-cw":
            return IconMotion(0.7, whole: { t in PartPose(rotate(360 * easeInOut(t))) })
        case "lock":
            return IconMotion(0.6, part: { i, t in
                i == 1 ? PartPose(move(0, -2.5 * bump(seg(t, 0, 0.55))).concatenating(rotate(-10 * bump(seg(t, 0, 0.55)), 17, 11)))
                       : PartPose(move(0.6 * wobble(t, 3), 0))
            })
        case "clock-3":
            return IconMotion(0.8, part: { i, t in i == 1 ? PartPose(rotate(360 * easeInOut(t))) : PartPose() })
        case "wifi":
            let order: [Int: Double] = [0: 0, 3: 1, 2: 2, 1: 3]
            return IconMotion(0.8, part: { i, t in
                let k = order[i] ?? 0
                return PartPose(opacity: 1 - 0.8 * bump(seg(t, 0.12 * k, 0.4 + 0.12 * k)))
            })
        case "globe":
            return IconMotion(0.9, part: { i, t in i == 1 ? PartPose(scale(cos(2 * .pi * easeInOut(t)), 1)) : PartPose() })

        // Profiles
        case "briefcase":
            return IconMotion(0.6, part: { i, t in
                let lift = move(0, -2 * bump(t)).concatenating(rotate(-8 * wobble(t, 1.5), 12, 20))
                return i == 0 ? PartPose(move(0, -0.8 * bump(t)).concatenating(lift)) : PartPose(lift)
            })
        case "gamepad-2":
            return IconMotion(0.6, part: { i, t in
                let rumble = move(0.9 * sin(2 * .pi * 6 * t) * (1 - t), 0)
                switch i {
                case 0, 1: return PartPose(rotate(90 * easeInOut(t), 8, 11).concatenating(rumble))
                case 2: return PartPose(scale(1 + 0.8 * bump(seg(t, 0.1, 0.5)), nil, 15, 12).concatenating(rumble))
                case 3: return PartPose(scale(1 + 0.8 * bump(seg(t, 0.25, 0.65)), nil, 18, 10).concatenating(rumble))
                default: return PartPose(rumble)
                }
            })
        case "moon":
            return IconMotion(0.8, whole: { t in PartPose(rotate(-25 * wobble(t, 1.2)).concatenating(scale(1 + 0.1 * bump(t)))) })
        case "star":
            return IconMotion(0.6, whole: { t in PartPose(rotate(72 * backOut(t)).concatenating(scale(1 + 0.2 * bump(t)))) })
        case "coffee":
            let order: [Int: Double] = [3: 0, 0: 1, 1: 2]
            return IconMotion(0.9, part: { i, t in
                guard let k = order[i] else { return PartPose() }
                let local = seg(t, 0.12 * k, 0.6 + 0.12 * k)
                return PartPose(move(0, -2 * bump(local)), opacity: 1 - 0.8 * bump(local))
            })
        case "code":
            return IconMotion(0.5, part: { i, t in PartPose(move((i == 0 ? 2.5 : -2.5) * bump(t), 0)) })
        case "film":
            return IconMotion(0.7, part: { i, t in
                guard i > 0 else { return PartPose(move(0, 0.8 * wobble(t, 2))) }
                let k = Double(i)
                return PartPose(move(0, 0.8 * wobble(t, 2)), opacity: 1 - 0.7 * bump(seg(t, 0.07 * k, 0.3 + 0.07 * k)))
            })
        case "video":
            return IconMotion(0.6, part: { i, t in
                i == 0 ? PartPose(move(1.2 * wobble(t, 2), 0)) : PartPose(scale(1 + 0.08 * bump(t)))
            })
        case "piano":
            let order: [Int: Double] = [5: 0, 0: 1, 1: 2, 2: 3]
            return IconMotion(0.7, part: { i, t in
                guard let k = order[i] else { return PartPose() }
                return PartPose(move(0, 1.5 * bump(seg(t, 0.12 * k, 0.35 + 0.12 * k))))
            })

        // Interface
        case "search":
            return IconMotion(0.6, whole: { t in
                PartPose(rotate(-12 * wobble(t, 2), 11, 11).concatenating(scale(1 + 0.15 * bump(t), nil, 11, 11)))
            })
        case "settings":
            return IconMotion(0.8, part: { i, t in
                i == 0 ? PartPose(rotate(120 * easeInOut(t))) : PartPose(scale(1 + 0.25 * bump(t)))
            })
        case "settings-2":
            return IconMotion(0.7, part: { i, t in
                switch i {
                case 3: PartPose(move(5 * bump(seg(t, 0, 0.8)), 0))
                case 2: PartPose(move(-5 * bump(seg(t, 0.15, 0.95)), 0))
                default: PartPose()
                }
            })
        case "sliders-horizontal":
            return IconMotion(0.8, part: { i, t in
                switch i {
                case 2: PartPose(move(-4 * bump(seg(t, 0, 0.6)), 0))
                case 7: PartPose(move(4 * bump(seg(t, 0.1, 0.7)), 0))
                case 3: PartPose(move(-3 * bump(seg(t, 0.2, 0.8)), 0))
                default: PartPose()
                }
            })
        case "plus":
            return IconMotion(0.5, whole: { t in PartPose(rotate(90 * backOut(t)).concatenating(scale(1 + 0.2 * bump(t)))) })
        case "x":
            return IconMotion(0.5, whole: { t in PartPose(rotate(90 * backOut(t)).concatenating(scale(1 - 0.15 * bump(t)))) })
        case "minus":
            return IconMotion(0.4, whole: { t in PartPose(scale(1 + 0.35 * bump(t), 1)) })
        case "check":
            return IconMotion(0.55, part: { _, t in
                PartPose(scale(1 + 0.15 * bump(seg(t, 0.4, 1))), trim: draw(easeOut(seg(t, 0, 0.6))))
            })
        case "chevrons-up-down":
            return IconMotion(0.45, part: { i, t in PartPose(move(0, (i == 0 ? 2 : -2) * bump(t))) })
        case "chevron-down":
            return IconMotion(0.55, whole: { t in PartPose(move(0, 2 * abs(sin(2 * .pi * t)) * (1 - t))) })
        case "chevron-right":
            return IconMotion(0.4, whole: { t in PartPose(move(2.5 * bump(t), 0)) })
        case "ellipsis":
            let order: [Int: Double] = [2: 0, 0: 1, 1: 2]
            return IconMotion(0.7, part: { i, t in
                let k = order[i] ?? 0
                return PartPose(move(0, -3 * bump(seg(t, 0.12 * k, 0.5 + 0.12 * k))))
            })
        case "grip-vertical":
            return IconMotion(0.6, part: { i, t in
                PartPose(move(0, (i < 3 ? -1.5 : 1.5) * sin(2 * .pi * 2 * t) * (1 - t)))
            })
        case "mouse-pointer-2":
            return IconMotion(0.45, whole: { t in
                let press = bump(seg(t, 0, 0.5))
                return PartPose(scale(1 - 0.25 * press, nil, 5, 5).concatenating(move(0.8 * press, 0.8 * press)))
            })
        case "arrow-down-to-line":
            return IconMotion(0.6, part: { i, t in
                i == 2 ? PartPose(scale(1 + 0.2 * bump(seg(t, 0.3, 0.8)), 1, 12, 21))
                       : PartPose(move(0, 3 * bump(seg(t, 0, 0.5))))
            })
        case "arrow-right":
            return IconMotion(0.6, whole: { t in passThrough(t, dx: 10, dy: 0) })
        case "send":
            return IconMotion(0.65, whole: { t in passThrough(t, dx: 8, dy: -8) })
        case "arrow-right-left":
            return IconMotion(0.6, part: { i, t in
                i < 2 ? PartPose(move(3 * bump(t), 0)) : PartPose(move(-3 * bump(seg(t, 0.1, 0.9)), 0))
            })
        case "corner-down-right":
            return IconMotion(0.6, part: { i, t in
                i == 1 ? PartPose(trim: draw(easeOut(seg(t, 0, 0.6)))) : PartPose(move(2 * bump(seg(t, 0.5, 1)), 0))
            })
        case "external-link":
            return IconMotion(0.5, part: { i, t in
                i < 2 ? PartPose(move(2 * bump(t), -2 * bump(t))) : PartPose(scale(1 - 0.05 * bump(t)))
            })
        case "workflow":
            return IconMotion(0.75, part: { i, t in
                switch i {
                case 1: PartPose(trim: draw(easeOut(seg(t, 0.15, 0.7))))
                case 0: PartPose(scale(1 + 0.25 * bump(seg(t, 0, 0.4)), nil, 7, 7))
                default: PartPose(scale(1 + 0.25 * bump(seg(t, 0.5, 0.95)), nil, 17, 17))
                }
            })
        case "route":
            return IconMotion(0.8, part: { i, t in
                switch i {
                case 1: PartPose(trim: draw(easeOut(seg(t, 0.1, 0.7))))
                case 0: PartPose(scale(1 + 0.35 * bump(seg(t, 0, 0.3)), nil, 6, 19))
                default: PartPose(scale(1 + 0.35 * bump(seg(t, 0.65, 1)), nil, 18, 5))
                }
            })
        case "list":
            return IconMotion(0.6, part: { i, t in
                let row = Double(i % 3), y = [5.0, 12, 19][i % 3]
                let local = seg(t, 0.1 * row, 0.5 + 0.1 * row)
                return i < 3 ? PartPose(scale(1 + 0.8 * bump(local), nil, 3, y))
                             : PartPose(scale(0.2 + 0.8 * easeOut(local), 1, 8, y))
            })
        case "layout-grid":
            let centers: [(Double, Double)] = [(6.5, 6.5), (17.5, 6.5), (17.5, 17.5), (6.5, 17.5)]
            return IconMotion(0.7, part: { i, t in
                let k = Double(i), c = centers[min(i, 3)]
                return PartPose(scale(1 - 0.35 * bump(seg(t, 0.12 * k, 0.45 + 0.12 * k)), nil, c.0, c.1))
            })
        case "layers":
            return IconMotion(0.6, part: { i, t in
                switch i {
                case 0: PartPose(move(0, -2.2 * bump(t)))
                case 2: PartPose(move(0, 2.2 * bump(t)))
                default: PartPose()
                }
            })
        case "app-window":
            return IconMotion(0.5, whole: { t in PartPose(scale(0.6 + 0.4 * backOut(t)), opacity: easeOut(seg(t, 0, 0.3))) })
        case "trash-2":
            return IconMotion(0.6, part: { i, t in
                switch i {
                case 3, 4: PartPose(rotate(-18 * bump(seg(t, 0, 0.7)), 3, 6).concatenating(move(0, -bump(seg(t, 0, 0.7)))))
                case 0, 1: PartPose(move(0, 0.6 * bump(seg(t, 0.2, 0.8))))
                default: PartPose()
                }
            })
        case "pencil":
            return IconMotion(0.7, whole: { t in PartPose(rotate(10 * wobble(t, 2.5), 3, 21)) })
        case "play":
            return IconMotion(0.45, whole: { t in PartPose(move(1.5 * bump(t), 0).concatenating(scale(1 + 0.15 * bump(t)))) })
        case "pause":
            return IconMotion(0.5, part: { i, t in
                i == 0 ? PartPose(scale(1, 1 - 0.3 * bump(seg(t, 0, 0.5)), 16.5, 12))
                       : PartPose(scale(1, 1 - 0.3 * bump(seg(t, 0.2, 0.7)), 7.5, 12))
            })
        case "file-text":
            return IconMotion(0.7, part: { i, t in
                guard i >= 2 else { return PartPose(scale(1 + 0.05 * bump(t))) }
                let k = Double(i - 2)
                return PartPose(trim: draw(easeOut(seg(t, 0.15 * k, 0.45 + 0.15 * k))))
            })
        case "scroll-text":
            return IconMotion(0.6, part: { i, t in
                switch i {
                case 1: PartPose(trim: draw(easeOut(seg(t, 0, 0.5))))
                case 0: PartPose(trim: draw(easeOut(seg(t, 0.2, 0.7))))
                default: PartPose(move(0, -bump(t)))
                }
            })
        case "life-buoy":
            return IconMotion(0.7, whole: { t in PartPose(rotate(90 * easeInOut(t))) })
        case "compass":
            return IconMotion(1.0, part: { i, t in i == 1 ? PartPose(rotate(50 * wobble(t, 1.5))) : PartPose() })
        case "hash":
            return IconMotion(0.6, whole: { t in PartPose(rotate(15 * wobble(t, 1.5))) })
        case "message-circle", "message-square":
            return IconMotion(0.6, whole: { t in PartPose(rotate(-8 * wobble(t, 1.5), 6, 20).concatenating(scale(1 + 0.15 * bump(t)))) })
        case "circle":
            return IconMotion(0.5, whole: { t in PartPose(scale(1 + 0.2 * bump(t)), opacity: 1 - 0.4 * bump(t)) })

        default:
            return IconMotion(0.45, whole: { t in PartPose(scale(1 + 0.2 * bump(t))) })
        }
    }
}
