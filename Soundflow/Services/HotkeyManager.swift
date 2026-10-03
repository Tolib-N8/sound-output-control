import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon `RegisterEventHotKey` (works without Accessibility permission).
@MainActor
final class HotkeyManager {
    private unowned let model: AppModel
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    fileprivate static weak var current: HotkeyManager?

    init(model: AppModel) {
        self.model = model
        HotkeyManager.current = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &type, nil, &handler)
    }

    /// Temporarily releases every shortcut (while the user records a new one).
    func suspend() { unregisterAll() }

    func registerAll() {
        unregisterAll()
        let prefs = model.config.prefs
        for (action, hotkey) in prefs.hotkeys {
            register(hotkey) { [weak self] in self?.perform(action) }
        }
        for profile in model.config.profiles {
            // A bare ⌘+digit would steal tab switching from every app, so those stay in-app menu shortcuts.
            guard let hotkey = profile.hotkey, hotkey.modifiers != [.command] else { continue }
            let id = profile.id
            register(hotkey) { [weak self] in self?.model.profiles.toggle(id) }
        }
    }

    private func register(_ hotkey: Hotkey, action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5346_4C57), id: nextID) // 'SFLW'
        let status = RegisterEventHotKey(UInt32(hotkey.key.code), hotkey.modifiers.carbon, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs.append(ref)
        actions[nextID] = action
        nextID += 1
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    // MARK: - Actions

    func perform(_ action: HotkeyAction) {
        switch action {
        case .openApp: model.openMainWindow?()
        case .openMap:
            model.mode = .map
            model.openMainWindow?()
        case .muteAll: model.muteAll()
        case .volumeUp: adjustActive(by: 0.05)
        case .volumeDown: adjustActive(by: -0.05)
        case .muteActive: if let app = activeApp { model.toggleMute(app.bundleID) }
        case .nextOutputForActive:
            guard let app = activeApp else { return }
            let options = model.outputOptions.filter(\.connected)
            guard !options.isEmpty else { return }
            let current = model.rule(app.bundleID).outputs.first ?? model.devices.defaultOutputUID
            let index = options.firstIndex { $0.ref == current } ?? -1
            model.assign(app.bundleID, to: options[(index + 1) % options.count].ref)
        case .nextMainDevice: model.nextMainDevice()
        case .switchDevice1, .switchDevice2:
            let target = model.config.prefs.deviceHotkeyTargets[action]
                ?? model.visibleDevices.dropFirst(action == .switchDevice1 ? 0 : 1).first?.uid
            if let target { model.makeDefault(target) }
        }
    }

    /// The frontmost app if it makes sound, otherwise the most recent one that is playing.
    private var activeApp: AudioApp? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return model.apps.first { $0.bundleID == front } ?? model.apps.first(where: \.isPlaying)
    }

    private func adjustActive(by delta: Double) {
        guard let app = activeApp else { return }
        model.setVolume(app.bundleID, model.rule(app.bundleID).volume + delta)
    }
}

private func hotkeyCallback(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    let value = id.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotkeyManager.current?.fire(value) }
    }
    return noErr
}
