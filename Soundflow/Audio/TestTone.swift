import CoreAudio
import Foundation

/// Plays a short chime on output devices ("Проверить звук").
enum TestTone {
    private final class Player: @unchecked Sendable {
        let device: AudioObjectID
        var procID: AudioDeviceIOProcID?
        var phase: Double = 0
        var frame = 0

        init(device: AudioObjectID) { self.device = device }
    }

    /// Plays on each device in turn order, delayed per device (milliseconds) to preview alignment.
    static func play(on uids: [String], delays: [String: Double] = [:], duration: Double = 0.7) {
        for uid in uids {
            guard let id = CA.deviceID(forUID: uid) else { continue }
            let delay = (delays[uid] ?? 0) / 1000
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                start(id, duration: duration)
            }
        }
    }

    private static func start(_ id: AudioObjectID, duration: Double) {
        let player = Player(device: id)
        let rate: Float64 = (try? CA.get(id, .init(kAudioDevicePropertyNominalSampleRate), default: Float64(48000))) ?? 48000
        let total = Int(rate * duration)
        let status = AudioDeviceCreateIOProcIDWithBlock(&player.procID, id, nil) { _, _, _, output, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            var lastFrame = player.frame
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frames = Int(buffer.mDataByteSize) / (4 * channels)
                var phase = player.phase
                for i in 0..<frames {
                    let n = player.frame + i
                    // Two-note chime with a soft attack/decay envelope.
                    let frequency = n < total / 2 ? 660.0 : 880.0
                    let local = Double(n % (total / 2)) / Double(total / 2)
                    let envelope = n < total ? min(local * 20, 1) * (1 - local) : 0
                    let sample = Float(sin(phase) * 0.25 * envelope)
                    phase += 2 * .pi * frequency / rate
                    for c in 0..<channels { data[i * channels + c] = sample }
                }
                lastFrame = player.frame + frames
                if buffer.mData == buffers.last?.mData { player.phase = phase }
            }
            player.frame = lastFrame
        }
        guard status == noErr, let procID = player.procID else { return }
        AudioDeviceStart(id, procID)
        DispatchQueue.global().asyncAfter(deadline: .now() + duration + 0.1) {
            AudioDeviceStop(id, procID)
            AudioDeviceDestroyIOProcID(id, procID)
            _ = player
        }
    }
}
