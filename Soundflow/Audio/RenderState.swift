import CoreAudio
import Foundation

/// Parameters shared between the main thread and a real-time IOProc.
///
/// Values live in raw memory and are read/written as aligned 32-bit words, which is lock- and
/// allocation-free on Apple Silicon and Intel; a torn update is impossible for single words.
final class RenderState: @unchecked Sendable {
    private enum Slot: Int, CaseIterable {
        case targetGain, balance, normalize, currentGain, agcGain, envelope, peakL, peakR
        case cycles, renderNanos, overloads, inputOffset, budgetNanos
    }

    private let storage: UnsafeMutablePointer<Float>

    init() {
        storage = .allocate(capacity: Slot.allCases.count)
        storage.initialize(repeating: 0, count: Slot.allCases.count)
        storage[Slot.targetGain.rawValue] = 1
        storage[Slot.currentGain.rawValue] = 1
        storage[Slot.agcGain.rawValue] = 1
        storage[Slot.envelope.rawValue] = 0.1
    }

    deinit { storage.deallocate() }

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

    // Render thread → main thread
    var peak: (left: Float, right: Float) { (self[.peakL], self[.peakR]) }
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

        var peakL: Float = 0, peakR: Float = 0
        for (bufferIndex, buffer) in outputs.enumerated() {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let out = data.assumingMemoryBound(to: Float.self)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let count = min(frames, outFrames)
            var gain = startGain
            for frame in 0..<count {
                gain += step
                let l = clamp(left[frame * stride] * gain * leftPan)
                let r = clamp(right[frame * stride + rightOffset] * gain * rightPan)
                let base = frame * channels
                if channels == 1 {
                    out[base] = (l + r) * 0.5
                } else {
                    out[base] = l
                    out[base + 1] = r
                    if channels > 2 { for extra in 2..<channels { out[base + extra] = 0 } }
                }
                if bufferIndex == 0 {
                    peakL = max(peakL, abs(l))
                    peakR = max(peakR, abs(r))
                }
            }
            if count < outFrames {
                (out + count * channels).update(repeating: 0, count: (outFrames - count) * channels)
            }
        }
        self[.currentGain] = target
        self[.peakL] = max(self[.peakL], peakL)
        self[.peakR] = max(self[.peakR], peakR)
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
