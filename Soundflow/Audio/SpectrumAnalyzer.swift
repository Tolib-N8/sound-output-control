import Accelerate
import Foundation

/// Turns recent samples into smoothed, logarithmically spaced bands (0…1) for the visualizer.
final class SpectrumAnalyzer {
    let size: Int
    let bandCount: Int
    private let setup: vDSP_DFT_Setup
    private var window: [Float]
    private var samples: [Float]
    private var real: [Float], imag: [Float], outReal: [Float], outImag: [Float]
    private var magnitudes: [Float]
    private(set) var bands: [Float]

    /// - Parameters:
    ///   - size: FFT length (power of two).
    ///   - bandCount: number of output bars, spaced logarithmically from `minFrequency` to `maxFrequency`.
    init(size: Int = 2048, bandCount: Int = 40) {
        self.size = size
        self.bandCount = bandCount
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        samples = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size)
        imag = [Float](repeating: 0, count: size)
        outReal = [Float](repeating: 0, count: size)
        outImag = [Float](repeating: 0, count: size)
        magnitudes = [Float](repeating: 0, count: size / 2)
        bands = [Float](repeating: 0, count: bandCount)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// Frequency edges of each band (Hz).
    static func bandEdges(count: Int, minFrequency: Double = 40, maxFrequency: Double = 16000) -> [Double] {
        (0...count).map { minFrequency * pow(maxFrequency / minFrequency, Double($0) / Double(count)) }
    }

    /// Reads the latest samples from `state` and updates `bands`. Returns false when there's no signal.
    @discardableResult
    func update(from state: RenderState) -> Bool {
        samples.withUnsafeMutableBufferPointer { state.recentSamples(into: $0.baseAddress!, count: size) }
        return analyze(sampleRate: state.sampleRate)
    }

    /// Analyzes `samples` (exposed for tests through `analyze(_:sampleRate:)`).
    @discardableResult
    func analyze(_ input: [Float], sampleRate: Double) -> Bool {
        samples = Array(input.prefix(size)) + [Float](repeating: 0, count: max(0, size - input.count))
        return analyze(sampleRate: sampleRate)
    }

    private func analyze(sampleRate: Double) -> Bool {
        vDSP_vmul(samples, 1, window, 1, &real, 1, vDSP_Length(size))
        imag.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        vDSP_DFT_Execute(setup, real, imag, &outReal, &outImag)

        var peak: Float = 0
        for bin in 0..<(size / 2) {
            let magnitude = (outReal[bin] * outReal[bin] + outImag[bin] * outImag[bin]).squareRoot() * 4 / Float(size)
            magnitudes[bin] = magnitude
            peak = max(peak, magnitude)
        }

        let edges = Self.bandEdges(count: bandCount)
        let binWidth = sampleRate / Double(size)
        for band in 0..<bandCount {
            let low = max(1, Int(edges[band] / binWidth))
            let high = max(low + 1, min(size / 2, Int(edges[band + 1] / binWidth) + 1))
            var level: Float = 0
            for bin in low..<high { level = max(level, magnitudes[bin]) }
            // −60 dBFS … 0 dBFS → 0…1, with a gentle tilt so highs aren't always tiny.
            let db = 20 * log10(max(level, 1e-6)) + Float(band) / Float(bandCount) * 6
            let target = min(1, max(0, (db + 60) / 60))
            // Fast attack, slow release.
            bands[band] = target > bands[band] ? bands[band] + (target - bands[band]) * 0.6 : bands[band] * 0.86 + target * 0.14
        }
        return peak > 1e-5
    }

    /// Lets the bars fall when nothing is playing.
    func decay() {
        for index in bands.indices { bands[index] *= 0.85 }
    }
}
