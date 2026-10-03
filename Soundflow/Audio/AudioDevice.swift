import CoreAudio
import Foundation

enum DeviceTransport: String, Codable, Sendable {
    case builtIn, bluetooth, usb, displayPort, hdmi, airPlay, thunderbolt, aggregate, virtual, multiOutput, other

    init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .builtIn: "Встроенные"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .displayPort: "DisplayPort"
        case .hdmi: "HDMI"
        case .airPlay: "AirPlay"
        case .thunderbolt: "Thunderbolt"
        case .aggregate: "Агрегат"
        case .virtual: "Виртуальное"
        case .multiOutput: "Агрегат"
        case .other: "Аудио"
        }
    }
}

enum DeviceKind: String, Codable, Sendable {
    case laptop, headphones, display, interface, multiOutput, tv, speaker

    var icon: String {
        switch self {
        case .laptop: "laptop"
        case .headphones: "headphones"
        case .display: "monitor"
        case .interface: "audio-lines"
        case .multiOutput: "git-merge"
        case .tv: "tv"
        case .speaker: "speaker"
        }
    }
}

/// Snapshot of a hardware output device.
struct AudioDevice: Identifiable, Hashable, Sendable {
    var id: String { uid }
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transport: DeviceTransport
    let modelUID: String
    var sampleRate: Double
    var availableSampleRates: [Double]
    var bitDepth: Int
    var outputChannels: Int
    var hasInput: Bool
    var volume: Float?
    var muted: Bool
    var canMute: Bool
    var latencyFrames: UInt32

    var kind: DeviceKind {
        let lower = name.lowercased()
        switch transport {
        case .builtIn: return lower.contains("display") ? .display : .laptop
        case .bluetooth:
            return lower.contains("airpods") || lower.contains("buds") || lower.contains("headphone") || lower.contains("наушник") || lower.contains("beats") ? .headphones : .speaker
        case .displayPort, .thunderbolt: return .display
        case .hdmi: return lower.contains("tv") ? .tv : .display
        case .airPlay: return .tv
        case .usb: return lower.contains("headset") ? .headphones : .interface
        case .aggregate, .multiOutput: return .multiOutput
        case .virtual, .other: return .interface
        }
    }

    var shortName: String {
        let lower = name.lowercased()
        if transport == .builtIn, lower.contains("macbook") || lower.contains("speaker") || lower.contains("динамик") { return "MacBook" }
        if lower.contains("airpods") { return "AirPods" }
        if let first = name.split(separator: " ").first, name.count > 12 { return String(first) }
        return name
    }

    var formatDescription: String {
        let khz = sampleRate / 1000
        let rate = khz.rounded() == khz ? "\(Int(khz)) кГц" : String(format: "%.1f кГц", khz)
        return transport == .usb && bitDepth > 16 ? "\(rate) / \(bitDepth) бит" : rate
    }

    var latencyMs: Double { sampleRate > 0 ? Double(latencyFrames) / sampleRate * 1000 : 0 }
}

extension AudioDevice {
    static let privateUIDPrefix = "com.tolibnosirov.soundflow."

    /// Reads a device; returns nil for devices without output streams or our own private aggregates.
    static func read(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = try? CA.string(id, .init(kAudioDevicePropertyDeviceUID)),
              !uid.hasPrefix(privateUIDPrefix), uid != "CADefaultDeviceAggregate" else { return nil }
        let outputStreams = (try? CA.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioStreamID.self)) ?? []
        guard !outputStreams.isEmpty else { return nil }
        let inputStreams = (try? CA.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), of: AudioStreamID.self)) ?? []

        let name = (try? CA.string(id, .init(kAudioObjectPropertyName))) ?? uid
        let transportCode: UInt32 = (try? CA.get(id, .init(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
        let model = (try? CA.string(id, .init(kAudioDevicePropertyModelUID))) ?? ""
        let rate: Float64 = (try? CA.get(id, .init(kAudioDevicePropertyNominalSampleRate), default: Float64(0))) ?? 0
        let ranges = (try? CA.getArray(id, .init(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)) ?? []
        let rates = Array(Set(ranges.flatMap { range in
            [44100.0, 48000, 88200, 96000, 176400, 192000].filter { $0 >= range.mMinimum && $0 <= range.mMaximum }
        })).sorted()

        var bitDepth = 32
        if let stream = outputStreams.first,
           let format: AudioStreamBasicDescription = try? CA.get(stream, .init(kAudioStreamPropertyPhysicalFormat), default: AudioStreamBasicDescription()) {
            bitDepth = Int(format.mBitsPerChannel)
        }
        var channels = 0
        if let configs = try? channelCount(id) { channels = configs }

        let latency: UInt32 = (try? CA.get(id, .init(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput), default: UInt32(0))) ?? 0
        let safety: UInt32 = (try? CA.get(id, .init(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), default: UInt32(0))) ?? 0
        let streamLatency: UInt32 = outputStreams.first.flatMap { try? CA.get($0, .init(kAudioStreamPropertyLatency), default: UInt32(0)) } ?? 0

        return AudioDevice(
            objectID: id, uid: uid, name: name,
            transport: DeviceTransport(code: transportCode),
            modelUID: model,
            sampleRate: rate,
            availableSampleRates: rates,
            bitDepth: bitDepth,
            outputChannels: channels,
            hasInput: !inputStreams.isEmpty,
            volume: DeviceVolume.get(id),
            muted: DeviceVolume.isMuted(id),
            canMute: CA.isSettable(id, .init(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)),
            latencyFrames: latency + safety + streamLatency
        )
    }

    private static func channelCount(_ id: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "stream config size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw), "stream config")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Device-level volume, using the virtual main volume when available and falling back to channels.
enum DeviceVolume {
    private static let virtualMain = AudioObjectPropertySelector(0x766D_7663) // 'vmvc' kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    static func get(_ id: AudioObjectID) -> Float? {
        let virtual = AudioObjectPropertyAddress(virtualMain, kAudioObjectPropertyScopeOutput)
        if CA.has(id, virtual), let value: Float32 = try? CA.get(id, virtual, default: Float32(0)) { return value }
        for element: UInt32 in [0, 1] {
            let address = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            if CA.has(id, address), let value: Float32 = try? CA.get(id, address, default: Float32(0)) { return value }
        }
        return nil
    }

    static func set(_ id: AudioObjectID, _ value: Float) {
        let value = max(0, min(1, value))
        let virtual = AudioObjectPropertyAddress(virtualMain, kAudioObjectPropertyScopeOutput)
        if CA.has(id, virtual), CA.isSettable(id, virtual) {
            try? CA.set(id, virtual, Float32(value))
            return
        }
        for element: UInt32 in [0, 1, 2] {
            let address = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            if CA.has(id, address), CA.isSettable(id, address) { try? CA.set(id, address, Float32(value)) }
        }
    }

    static func isMuted(_ id: AudioObjectID) -> Bool {
        let address = AudioObjectPropertyAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard CA.has(id, address) else { return false }
        return ((try? CA.get(id, address, default: UInt32(0))) ?? 0) != 0
    }

    static func setMuted(_ id: AudioObjectID, _ muted: Bool) {
        let address = AudioObjectPropertyAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        if CA.has(id, address) { try? CA.set(id, address, UInt32(muted ? 1 : 0)) }
    }

    static var volumeAddresses: [AudioObjectPropertyAddress] {
        [AudioObjectPropertyAddress(virtualMain, kAudioObjectPropertyScopeOutput),
         AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0),
         AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1),
         AudioObjectPropertyAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)]
    }
}
