import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    var description: String {
        let code = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let fourCC = chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") } ? "'\(String(chars))'" : "\(status)"
        return "\(context): \(fourCC)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, context: context()) }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Thin typed wrappers over the AudioObject property C API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, default value: T) throws -> T {
        var address = address
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), "get \(address.mSelector)")
        return result
    }

    static func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size \(address.mSelector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer), "get \(address.mSelector)")
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "string \(address.mSelector)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectSetPropertyData(object, &address, 0, nil, size, &value), "set \(address.mSelector)")
    }

    /// Translates a device UID into its current AudioObjectID.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func process(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }
}

/// Keeps an `AudioObjectAddPropertyListenerBlock` registration alive and removes it on deinit.
final class PropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue
    private var active = false

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        active = AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block) == noErr
    }

    deinit {
        if active { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
    }
}
