import CoreAudio
import Foundation
import Observation

/// Observes the system's output devices and the default output.
@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [AudioDevice] = []
    private(set) var defaultOutputUID: String?

    /// Called with (appeared, disappeared) UIDs after the device list changes.
    @ObservationIgnored var onDevicesChanged: ((_ added: [AudioDevice], _ removed: [AudioDevice]) -> Void)?
    @ObservationIgnored var onDefaultChanged: (() -> Void)?

    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var deviceListeners: [AudioObjectID: [PropertyListener]] = [:]
    @ObservationIgnored private var refreshScheduled = false

    init() {
        reload(notify: false)
        let refresh: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        systemListeners = [
            PropertyListener(CA.system, .init(kAudioHardwarePropertyDevices), handler: refresh),
            PropertyListener(CA.system, .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.reloadDefault()
                    self?.onDefaultChanged?()
                }
            },
        ]
    }

    var defaultDevice: AudioDevice? { devices.first { $0.uid == defaultOutputUID } }

    func device(uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    func isConnected(_ uid: String) -> Bool { devices.contains { $0.uid == uid } }

    // MARK: - Mutations

    func setDefault(_ uid: String) {
        guard let device = device(uid: uid) else { return }
        try? CA.set(CA.system, .init(kAudioHardwarePropertyDefaultOutputDevice), device.objectID)
        try? CA.set(CA.system, .init(kAudioHardwarePropertyDefaultSystemOutputDevice), device.objectID)
        reloadDefault()
    }

    func setVolume(_ uid: String, _ value: Float) {
        guard let device = device(uid: uid) else { return }
        if value > 0, device.muted { DeviceVolume.setMuted(device.objectID, false) }
        DeviceVolume.set(device.objectID, value)
        update(uid) { $0.volume = value; if value > 0 { $0.muted = false } }
    }

    func setMuted(_ uid: String, _ muted: Bool) {
        guard let device = device(uid: uid) else { return }
        DeviceVolume.setMuted(device.objectID, muted)
        update(uid) { $0.muted = muted }
    }

    func setSampleRate(_ uid: String, _ rate: Double) {
        guard let device = device(uid: uid) else { return }
        try? CA.set(device.objectID, .init(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    func setBitDepth(_ uid: String, _ bits: Int) {
        guard let device = device(uid: uid),
              let streams = try? CA.getArray(device.objectID, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioStreamID.self)
        else { return }
        for stream in streams {
            guard let formats = try? CA.getArray(stream, .init(kAudioStreamPropertyAvailablePhysicalFormats), of: AudioStreamRangedDescription.self) else { continue }
            let match = formats.first {
                Int($0.mFormat.mBitsPerChannel) == bits && $0.mFormat.mSampleRate == device.sampleRate
            } ?? formats.first { Int($0.mFormat.mBitsPerChannel) == bits }
            if let match { try? CA.set(stream, .init(kAudioStreamPropertyPhysicalFormat), match.mFormat) }
        }
    }

    /// Makes sure the default input is not a Bluetooth headset (avoids the HFP "headset" mode).
    func avoidHeadsetInput() {
        guard let input: AudioObjectID = try? CA.get(CA.system, .init(kAudioHardwarePropertyDefaultInputDevice), default: AudioObjectID(0)),
              let code: UInt32 = try? CA.get(input, .init(kAudioDevicePropertyTransportType), default: UInt32(0)),
              DeviceTransport(code: code) == .bluetooth else { return }
        let all = (try? CA.getArray(CA.system, .init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
        let builtInMic = all.first { id in
            let inputs = (try? CA.getArray(id, .init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), of: AudioStreamID.self)) ?? []
            let transport: UInt32 = (try? CA.get(id, .init(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
            return !inputs.isEmpty && transport == kAudioDeviceTransportTypeBuiltIn
        }
        if let builtInMic { try? CA.set(CA.system, .init(kAudioHardwarePropertyDefaultInputDevice), builtInMic) }
    }

    // MARK: - Reloading

    private func scheduleReload() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Device lists change in bursts (e.g. Bluetooth connect); coalesce.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.reload(notify: true)
            }
        }
    }

    func reload(notify: Bool) {
        let ids = (try? CA.getArray(CA.system, .init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
        let fresh = ids.compactMap(AudioDevice.read)
        let old = devices
        devices = fresh
        reloadDefault()
        installDeviceListeners()
        if notify {
            let added = fresh.filter { device in !old.contains { $0.uid == device.uid } }
            let removed = old.filter { device in !fresh.contains { $0.uid == device.uid } }
            if !added.isEmpty || !removed.isEmpty { onDevicesChanged?(added, removed) }
        }
    }

    private func reloadDefault() {
        let id: AudioObjectID = (try? CA.get(CA.system, .init(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))) ?? 0
        defaultOutputUID = devices.first { $0.objectID == id }?.uid ?? (try? CA.string(id, .init(kAudioDevicePropertyDeviceUID)))
    }

    private func installDeviceListeners() {
        let current = Set(devices.map(\.objectID))
        deviceListeners = deviceListeners.filter { current.contains($0.key) }
        for device in devices where deviceListeners[device.objectID] == nil {
            let id = device.objectID
            let handler: @Sendable () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevice(id) }
            }
            var listeners = DeviceVolume.volumeAddresses.map { PropertyListener(id, $0, handler: handler) }
            listeners.append(PropertyListener(id, .init(kAudioDevicePropertyNominalSampleRate), handler: handler))
            listeners.append(PropertyListener(id, .init(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput), handler: handler))
            deviceListeners[id] = listeners
        }
    }

    private func refreshDevice(_ id: AudioObjectID) {
        guard let index = devices.firstIndex(where: { $0.objectID == id }), let fresh = AudioDevice.read(id) else { return }
        if devices[index] != fresh { devices[index] = fresh }
    }

    private func update(_ uid: String, _ change: (inout AudioDevice) -> Void) {
        guard let index = devices.firstIndex(where: { $0.uid == uid }) else { return }
        change(&devices[index])
    }
}
