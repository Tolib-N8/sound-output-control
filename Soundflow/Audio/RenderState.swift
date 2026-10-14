import CoreAudio
import Foundation

/// Parameters shared between the main thread and a real-time IOProc.
///
/// Values live in raw memory and are read/written as aligned 32-bit words, which is lock- and
/// allocation-free on Apple Silicon and Intel; a torn update is impossible for single words.
final class RenderState: @unchecked Sendable {
    private enum Slot: Int, CaseIterable {
        case targetGain, balance, normalize, currentGain, agcGain, envelope, peakL, peakR, rmsL, rmsR
        case cycles, renderNanos, overloads, inputOffset, budgetNanos
        case sampleRate, eqEnabled, eqBank, spectrumCapture
    }

    static let eqBands = 10
    static let spectrumCapacity = 4096
    private static let scratchFrames = 8192

    private let storage: UnsafeMutablePointer<Float>
    /// Processed interleaved stereo for one cycle, copied to every output buffer.
    private let scratch: UnsafeMutablePointer<Float>
    /// Two banks of biquad coefficients (b0 b1 b2 a1 a2 per band); the inactive one is rewritten, then flipped.
    private let eqCoefficients: UnsafeMutablePointer<Float>
    /// Filter memory: per band, per channel, z1 and z2.
    private let eqState: UnsafeMutablePointer<Float>
    /// Ring buffer of recent mono samples for the spectrum visualizer.
    private let spectrum: UnsafeMutablePointer<Float>
    private let spectrumWrite: UnsafeMutablePointer<Int>

    init() {
        storage = .allocate(capacity: Slot.allCases.count)
        storage.initialize(repeating: 0, count: Slot.allCases.count)
        scratch = .allocate(capacity: Self.scratchFrames * 2)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * 2)
        eqCoefficients = .allocate(capacity: 2 * Self.eqBands * 5)
        eqCoefficients.initialize(repeating: 0, count: 2 * Self.eqBands * 5)
        eqState = .allocate(capacity: Self.eqBands * 4)
        eqState.initialize(repeating: 0, count: Self.eqBands * 4)
        spectrum = .allocate(capacity: Self.spectrumCapacity)
        spectrum.initialize(repeating: 0, count: Self.spectrumCapacity)
        spectrumWrite = .allocate(capacity: 1)
        spectrumWrite.initialize(to: 0)
        storage[Slot.targetGain.rawValue] = 1
        storage[Slot.currentGain.rawValue] = 1
        storage[Slot.agcGain.rawValue] = 1
        storage[Slot.envelope.rawValue] = 0.1
        storage[Slot.sampleRate.rawValue] = 48000
    }

    deinit {
        storage.deallocate()
        scratch.deallocate()
        eqCoefficients.deallocate()
        eqState.deallocate()
        spectrum.deallocate()
        spectrumWrite.deallocate()
    }

    private subscript(_ slot: Slot) -> Float {
        get { storage[slot.rawValue] }
        set { storage[slot.rawValue] = newValue }
    }

    // Main thread → render thread
    var targetGain: Float { get { self[.targetGain] } set { self[.targetGain] = max(0, newValue) } }
    var balance: Float { get { self[.balance] } set { self[.balance] = max(-1, min(1, newValue)) } }
    var normalize: Bool { get { self[.normalize] != 0 } set { self[.normalize] = newValue ? 1 : 0 } }
    var inputOffset: Int { get { Int(self[.inputOffset]) } set { self[.inputOffset] = Float(newValue) } }
    /// Duration of one IO cycle in nanoseconds; used for load statistics.
    var budgetNanos: Float { get { self[.budgetNanos] } set { self[.budgetNanos] = newValue } }
    /// Sample rate of the router's clock device.
    var sampleRate: Double { get { Double(self[.sampleRate]) } set { self[.sampleRate] = Float(newValue) } }
    /// Record recent samples for the spectrum visualizer.
    var capturesSpectrum: Bool { get { self[.spectrumCapture] != 0 } set { self[.spectrumCapture] = newValue ? 1 : 0 } }
    var eqEnabled: Bool { self[.eqEnabled] != 0 }

    /// Installs equalizer filters without disturbing the render thread: the inactive bank is
    /// written first and then made current with a single word store.
    func setEqualizer(_ filters: [Biquad]?) {
        guard let filters, filters.count == Self.eqBands, filters.contains(where: { $0 != .identity }) else {
            self[.eqEnabled] = 0
            return
        }
        let wasEnabled = eqEnabled
        let bank = self[.eqBank] == 0 ? 1 : 0
        let base = eqCoefficients + bank * Self.eqBands * 5
        for (index, filter) in filters.enumerated() {
            let c = base + index * 5
            c[0] = Float(filter.b0); c[1] = Float(filter.b1); c[2] = Float(filter.b2)
            c[3] = Float(filter.a1); c[4] = Float(filter.a2)
        }
        if !wasEnabled { eqState.update(repeating: 0, count: Self.eqBands * 4) }
        self[.eqBank] = Float(bank)
        self[.eqEnabled] = 1
    }

    /// Copies the most recent `count` mono samples (oldest first) for spectrum analysis.
    func recentSamples(into buffer: UnsafeMutablePointer<Float>, count: Int) {
        let count = min(count, Self.spectrumCapacity)
        let end = spectrumWrite.pointee
        for i in 0..<count {
            buffer[i] = spectrum[(end - count + i) & (Self.spectrumCapacity - 1)]
        }
    }

    // Render thread → main thread
    var peak: (left: Float, right: Float) { (self[.peakL], self[.peakR]) }
    /// Loudness (RMS) per channel since the last decay — steadier than peaks for meters.
    var rms: (left: Float, right: Float) { (self[.rmsL], self[.rmsR]) }
    var cycles: Float { self[.cycles] }
    var overloads: Float { self[.overloads] }

    /// Average fraction of the IO budget spent rendering since the last call; resets the counters.
    func takeLoad() -> Double {
        let cycles = self[.cycles], nanos = self[.renderNanos], budget = self[.budgetNanos]
        self[.cycles] = 0
        self[.renderNanos] = 0
        guard cycles > 0, budget > 0 else { return 0 }
        return Double(nanos / cycles / budget)
    }

    func decayPeaks() {
        self[.peakL] *= 0.6
        self[.peakR] *= 0.6
        self[.rmsL] *= 0.7
        self[.rmsR] *= 0.7
    }

    private func recordRMS(_ sumL: Float, _ sumR: Float, frames: Int) {
        guard frames > 0 else { return }
        self[.rmsL] = max(self[.rmsL], (sumL / Float(frames)).squareRoot())
        self[.rmsR] = max(self[.rmsR], (sumR / Float(frames)).squareRoot())
    }

    // MARK: - Rendering

    /// Copies the tap's stereo signal into every output buffer, applying gain, balance and
    /// optional loudness normalization. Called on the real-time IO thread.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let start = mach_absolute_time()
        defer { recordTiming(since: start) }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let offset = min(inputOffset, inputs.count)

        guard offset < inputs.count, let first = inputs[offset].mData else {
            silence(outputs)
            return
        }

        // Describe the tap signal: one interleaved buffer, two mono buffers, or a single mono buffer.
        let firstChannels = max(1, Int(inputs[offset].mNumberChannels))
        let frames = Int(inputs[offset].mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        let left = first.assumingMemoryBound(to: Float.self)
        let rightBuffer: UnsafeMutablePointer<Float>?
        let stride: Int
        let rightOffset: Int
        if firstChannels >= 2 {
            rightBuffer = left; stride = firstChannels; rightOffset = 1
        } else if offset + 1 < inputs.count, let second = inputs[offset + 1].mData {
            rightBuffer = second.assumingMemoryBound(to: Float.self); stride = 1; rightOffset = 0
        } else {
            rightBuffer = left; stride = 1; rightOffset = 0
        }
        guard let right = rightBuffer, frames > 0 else {
            silence(outputs)
            return
        }

        // Gain ramp across the cycle avoids zipper noise on volume changes.
        var target = self[.targetGain]
        if self[.normalize] != 0 {
            target *= updateNormalization(left: left, right: right, stride: stride, rightOffset: rightOffset, frames: frames)
        }
        let startGain = self[.currentGain]
        let step = (target - startGain) / Float(frames)
        let balance = self[.balance]
        let leftPan: Float = balance > 0 ? 1 - balance : 1
        let rightPan: Float = balance < 0 ? 1 + balance : 1

        // Process once into the scratch buffer (stateful EQ must run exactly once per frame)…
        let count = min(frames, Self.scratchFrames)
        let bank: UnsafeMutablePointer<Float>? = self[.eqEnabled] != 0 ? eqCoefficients + Int(self[.eqBank]) * Self.eqBands * 5 : nil
        var peakL: Float = 0, peakR: Float = 0, sumL: Float = 0, sumR: Float = 0
        var gain = startGain
        for frame in 0..<count {
            gain += step
            var l = left[frame * stride] * gain * leftPan
            var r = right[frame * stride + rightOffset] * gain * rightPan
            if let bank {
                l = equalize(l, bank: bank, channel: 0)
                r = equalize(r, bank: bank, channel: 1)
            }
            l = clamp(l)
            r = clamp(r)
            scratch[frame * 2] = l
            scratch[frame * 2 + 1] = r
            peakL = max(peakL, abs(l))
            peakR = max(peakR, abs(r))
            sumL += l * l
            sumR += r * r
        }
        if self[.spectrumCapture] != 0 { captureSpectrum(scratch, stride: 2, rightOffset: 1, frames: count) }

        // …then copy it to every output buffer (multi-output devices).
        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let out = data.assumingMemoryBound(to: Float.self)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let n = min(count, outFrames)
            for frame in 0..<n {
                let l = scratch[frame * 2], r = scratch[frame * 2 + 1]
                let base = frame * channels
                if channels == 1 {
                    out[base] = (l + r) * 0.5
                } else {
                    out[base] = l
                    out[base + 1] = r
                    if channels > 2 { for extra in 2..<channels { out[base + extra] = 0 } }
                }
            }
            if n < outFrames {
                (out + n * channels).update(repeating: 0, count: (outFrames - n) * channels)
            }
        }
        self[.currentGain] = target
        self[.peakL] = max(self[.peakL], peakL)
        self[.peakR] = max(self[.peakR], peakR)
        recordRMS(sumL, sumR, frames: count)
    }

    /// Ten biquads in series (Transposed Direct Form II).
    @inline(__always)
    private func equalize(_ sample: Float, bank: UnsafeMutablePointer<Float>, channel: Int) -> Float {
        var x = sample
        for band in 0..<Self.eqBands {
            let c = bank + band * 5
            let z = eqState + (band * 2 + channel) * 2
            let y = c[0] * x + z[0]
            z[0] = c[1] * x - c[3] * y + z[1]
            z[1] = c[2] * x - c[4] * y
            x = y
        }
        return x
    }

    @inline(__always)
    private func captureSpectrum(_ samples: UnsafeMutablePointer<Float>, stride: Int, rightOffset: Int, frames: Int) {
        var index = spectrumWrite.pointee
        let mask = Self.spectrumCapacity - 1
        for frame in 0..<frames {
            spectrum[index & mask] = (samples[frame * stride] + samples[frame * stride + rightOffset]) * 0.5
            index &+= 1
        }
        spectrumWrite.pointee = index
    }

    /// Measures the tap's peak level without producing sound (the app keeps playing natively).
    func meter(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let start = mach_absolute_time()
        defer { recordTiming(since: start) }
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        silence(outputs)

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let offset = min(inputOffset, inputs.count)
        guard offset < inputs.count, let first = inputs[offset].mData else { return }
        let channels = max(1, Int(inputs[offset].mNumberChannels))
        let frames = Int(inputs[offset].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let samples = first.assumingMemoryBound(to: Float.self)
        var peakL: Float = 0, peakR: Float = 0, sumL: Float = 0, sumR: Float = 0
        for frame in 0..<frames {
            let l = samples[frame * channels], r = samples[frame * channels + (channels > 1 ? 1 : 0)]
            peakL = max(peakL, abs(l))
            peakR = max(peakR, abs(r))
            sumL += l * l
            sumR += r * r
        }
        self[.peakL] = max(self[.peakL], peakL)
        self[.peakR] = max(self[.peakR], peakR)
        recordRMS(sumL, sumR, frames: frames)
        if self[.spectrumCapture] != 0 {
            captureSpectrum(samples, stride: channels, rightOffset: channels > 1 ? 1 : 0, frames: frames)
        }
    }

    /// Slow automatic gain control towards a common loudness target.
    private func updateNormalization(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, stride: Int, rightOffset: Int, frames: Int) -> Float {
        var sum: Float = 0
        for frame in 0..<frames {
            let l = left[frame * stride], r = right[frame * stride + rightOffset]
            sum += l * l + r * r
        }
        let rms = (sum / Float(frames * 2)).squareRoot()
        var gain = self[.agcGain]
        if rms > 0.0005 {
            let envelope = self[.envelope] * 0.97 + rms * 0.03
            self[.envelope] = envelope
            let desired = max(0.35, min(2.5, 0.12 / max(envelope, 0.0001)))
            gain += (desired - gain) * 0.02
            self[.agcGain] = gain
        }
        return gain
    }

    private func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }

    private func recordTiming(since start: UInt64) {
        let elapsed = mach_absolute_time() &- start
        self[.cycles] += 1
        self[.renderNanos] += Float(MachTime.nanos(elapsed))
    }

    @inline(__always)
    private func clamp(_ sample: Float) -> Float { max(-1, min(1, sample)) }
}

enum MachTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanos(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    }
}
