import AudioToolbox
import CoreAudio
import Foundation
import os

/// What a router should do with an app's audio.
struct RouteConfig: Equatable, Sendable {
    let bundleID: String
    var processObjects: [AudioObjectID]
    /// Hardware output UIDs; the first one is the clock (main) device.
    var outputUIDs: [String]
    var driftCompensation: Bool = true
    /// Extra output latency in frames per device UID (used to align multi-outputs).
    var extraLatency: [String: UInt32] = [:]
    var bufferFrames: UInt32 = 256
    /// Drift-compensation resampler quality, 0 (min) … 4 (max).
    var resamplingQuality = 2
    /// Only measure the level: the app keeps playing natively and the router outputs silence.
    var monitorOnly = false

    func requiresRebuild(from other: RouteConfig) -> Bool {
        outputUIDs != other.outputUIDs || driftCompensation != other.driftCompensation
            || extraLatency != other.extraLatency || bufferFrames != other.bufferFrames
            || resamplingQuality != other.resamplingQuality || monitorOnly != other.monitorOnly
    }
}

let audioLog = Logger(subsystem: "com.tolibnosirov.Soundflow", category: "audio")

/// Captures one app with a Core Audio process tap (muting its original output) and plays the
/// processed signal through a private aggregate device made of the chosen output devices.
/// In `monitorOnly` mode the original output is left alone and the router only meters the signal.
final class AppRouter: @unchecked Sendable {
    let state: RenderState
    private(set) var config: RouteConfig

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue: DispatchQueue

    private(set) var latencyMs: Double = 0

    init(config: RouteConfig, state: RenderState) throws {
        self.config = config
        self.state = state
        ioQueue = DispatchQueue(label: "soundflow.io.\(config.bundleID)", qos: .userInteractive)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    /// Applies a new config, rebuilding the aggregate only when the outputs changed.
    func update(_ new: RouteConfig) throws {
        if new.requiresRebuild(from: config) {
            stop()
            config = new
            try start()
        } else if new.processObjects != config.processObjects {
            config = new
            updateTapProcesses()
        } else {
            config = new
        }
    }

    // MARK: - Lifecycle

    private func start() throws {
        guard let mainUID = config.outputUIDs.first else { throw CoreAudioError(status: -1, context: "no output") }

        // 1. Tap the app's processes (muting their original output unless we only meter).
        let processes = Self.alive(config.processObjects)
        guard !processes.isEmpty else { throw CoreAudioError(status: -1, context: "no live processes") }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Soundflow \(config.bundleID)"
        description.isPrivate = true
        description.muteBehavior = config.monitorOnly ? .unmuted : .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")
        tapDescription = description
        let tapUID = try CA.string(tapID, .init(kAudioTapPropertyUID))

        // 2. Build a private aggregate: chosen outputs + the tap as input.
        let subDevices: [[String: Any]] = config.outputUIDs.map { uid in
            var entry: [String: Any] = [
                kAudioSubDeviceUIDKey: uid,
                kAudioSubDeviceDriftCompensationKey: uid != mainUID && config.driftCompensation,
                kAudioSubDeviceDriftCompensationQualityKey: Self.qualities[config.resamplingQuality.clamped(to: 0...4)],
            ]
            if let extra = config.extraLatency[uid], extra > 0 { entry[kAudioSubDeviceExtraOutputLatencyKey] = extra }
            return entry
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundflow \(config.bundleID)",
            kAudioAggregateDeviceUIDKey: AudioDevice.privateUIDPrefix + "agg." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceClockDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")

        try? CA.set(aggregateID, .init(kAudioDevicePropertyBufferFrameSize), config.bufferFrames)

        // 3. Sub-device input streams (e.g. a headset mic) come before the tap; skip and disable them
        //    so Bluetooth headphones are never forced into the low-quality headset profile.
        let deviceInputStreams = config.outputUIDs.reduce(0) { total, uid in
            guard let id = CA.deviceID(forUID: uid) else { return total }
            let streams = (try? CA.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), of: AudioStreamID.self)) ?? []
            return total + streams.count
        }
        state.inputOffset = deviceInputStreams

        let rate: Float64 = (try? CA.get(aggregateID, .init(kAudioDevicePropertyNominalSampleRate), default: Float64(48000))) ?? 48000
        let frames: UInt32 = (try? CA.get(aggregateID, .init(kAudioDevicePropertyBufferFrameSize), default: UInt32(512))) ?? 512
        state.budgetNanos = Float(Double(frames) / rate * 1_000_000_000)
        let outputLatency: UInt32 = (try? CA.get(aggregateID, .init(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput), default: UInt32(0))) ?? 0
        let safety: UInt32 = (try? CA.get(aggregateID, .init(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), default: UInt32(0))) ?? 0
        latencyMs = Double(frames + outputLatency + safety) / rate * 1000

        // 4. Render.
        let state = self.state
        let monitorOnly = config.monitorOnly
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, output, _ in
            if monitorOnly {
                state.meter(input: input, output: output)
            } else {
                state.render(input: input, output: output)
            }
        }, "create IOProc")
        if deviceInputStreams > 0 { disableInputStreams(count: deviceInputStreams) }
        try check(AudioDeviceStart(aggregateID, procID), "start")
        audioLog.info("\(self.config.monitorOnly ? "Metering" : "Routing") \(self.config.bundleID, privacy: .public) → \(self.config.outputUIDs, privacy: .public)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapDescription = nil
    }

    private func updateTapProcesses() {
        guard tapID != kAudioObjectUnknown, let description = tapDescription else { return }
        let processes = Self.alive(config.processObjects)
        guard !processes.isEmpty else { return }
        description.processes = processes
        var address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var reference: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr {
            audioLog.error("Tap update failed (\(status)); rebuilding")
            stop()
            try? start()
        }
    }

    private static let qualities: [UInt32] = [
        kAudioSubDeviceDriftCompensationMinQuality, kAudioSubDeviceDriftCompensationLowQuality,
        kAudioSubDeviceDriftCompensationMediumQuality, kAudioSubDeviceDriftCompensationHighQuality,
        kAudioSubDeviceDriftCompensationMaxQuality,
    ]

    /// Process objects disappear as soon as a process exits; a tap on a dead one fails.
    private static func alive(_ objects: [AudioObjectID]) -> [AudioObjectID] {
        objects.filter { CA.has($0, .init(kAudioProcessPropertyPID)) }
    }

    /// Turns off the IOProc's use of the first `count` input streams (sub-device inputs).
    private func disableInputStreams(count: Int) {
        guard let procID else { return }
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr, size >= 16 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw) == noErr else { return }
        let streams = Int(raw.load(fromByteOffset: 8, as: UInt32.self))
        let flags = (raw + 12).bindMemory(to: UInt32.self, capacity: streams)
        for index in 0..<min(count, streams) { flags[index] = 0 }
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, raw)
        if status != noErr { audioLog.error("Stream usage failed: \(status)") }
    }
}
