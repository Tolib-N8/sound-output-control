import Foundation

/// Per-app 10-band equalizer settings (gains in dB).
struct EQSettings: Codable, Equatable, Sendable {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Double> = -12...12

    var enabled = true
    var gains: [Double] = Array(repeating: 0, count: 10)
    var preset: String? = EQPreset.flat.rawValue

    var isFlat: Bool { gains.allSatisfy { abs($0) < 0.05 } }
    /// Whether the equalizer actually changes the sound.
    var isActive: Bool { enabled && !isFlat }

    init(enabled: Bool = true, gains: [Double] = Array(repeating: 0, count: 10), preset: String? = EQPreset.flat.rawValue) {
        self.enabled = enabled
        self.gains = gains
        self.preset = preset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled, default: true)
        let decoded = try c.decode([Double].self, forKey: .gains, default: [])
        gains = (decoded + Array(repeating: 0, count: 10)).prefix(10).map { $0.clamped(to: Self.range) }
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
    }
}

enum EQPreset: String, CaseIterable, Identifiable, Sendable {
    case flat, bass, vocal, podcast, night, bright

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Плоский"
        case .bass: "Бас+"
        case .vocal: "Вокал"
        case .podcast: "Подкаст"
        case .night: "Ночной"
        case .bright: "Яркость"
        }
    }

    var gains: [Double] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .vocal: [-3, -2, -1, 0, 2, 4, 4, 3, 1, 0]
        case .podcast: [-6, -4, -2, 0, 2, 3, 3, 2, 0, -2]
        case .night: [-4, -3, -1, 0, 0, 1, 1, 0, -2, -4]
        case .bright: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
        }
    }
}

/// Biquad coefficients normalized by a0 (Transposed Direct Form II).
struct Biquad: Equatable {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0, a1: Double = 0, a2: Double = 0

    static let identity = Biquad()

    enum Kind { case lowShelf, peaking, highShelf }

    /// RBJ "Audio EQ Cookbook" filter.
    static func make(_ kind: Kind, frequency: Double, gainDB: Double, q: Double = 1.41, sampleRate: Double) -> Biquad {
        guard sampleRate > 0, frequency < sampleRate * 0.47, abs(gainDB) > 0.01 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peaking:
            let alpha = sinW / (2 * q)
            b0 = 1 + alpha * a; b1 = -2 * cosW; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW; a2 = 1 - alpha / a
        case .lowShelf, .highShelf:
            let alpha = sinW / 2 * (2.0).squareRoot() // shelf slope S = 1
            let rootA = a.squareRoot()
            if kind == .lowShelf {
                b0 = a * ((a + 1) - (a - 1) * cosW + 2 * rootA * alpha)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
                b2 = a * ((a + 1) - (a - 1) * cosW - 2 * rootA * alpha)
                a0 = (a + 1) + (a - 1) * cosW + 2 * rootA * alpha
                a1 = -2 * ((a - 1) + (a + 1) * cosW)
                a2 = (a + 1) + (a - 1) * cosW - 2 * rootA * alpha
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosW + 2 * rootA * alpha)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
                b2 = a * ((a + 1) + (a - 1) * cosW - 2 * rootA * alpha)
                a0 = (a + 1) - (a - 1) * cosW + 2 * rootA * alpha
                a1 = 2 * ((a - 1) - (a + 1) * cosW)
                a2 = (a + 1) - (a - 1) * cosW - 2 * rootA * alpha
            }
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude response in dB at `frequency` (for drawing the curve).
    func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w), numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = 1 + a1 * cos(w) + a2 * cos(2 * w), denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let magnitude = ((numRe * numRe + numIm * numIm) / max(1e-12, denRe * denRe + denIm * denIm)).squareRoot()
        return 20 * log10(max(magnitude, 1e-9))
    }
}

enum Equalizer {
    /// Ten filters: shelves at the ends, peaking bands in between.
    static func filters(for settings: EQSettings, sampleRate: Double) -> [Biquad] {
        EQSettings.frequencies.enumerated().map { index, frequency in
            let kind: Biquad.Kind = index == 0 ? .lowShelf : index == EQSettings.frequencies.count - 1 ? .highShelf : .peaking
            return Biquad.make(kind, frequency: frequency, gainDB: settings.enabled ? settings.gains[index] : 0, sampleRate: sampleRate)
        }
    }

    /// Combined response of the whole chain in dB.
    static func responseDB(_ filters: [Biquad], at frequency: Double, sampleRate: Double) -> Double {
        filters.reduce(0) { $0 + $1.responseDB(at: frequency, sampleRate: sampleRate) }
    }
}
