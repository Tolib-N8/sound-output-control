import AppKit
import Foundation

/// "System Audio Recording" (TCC `kTCCServiceAudioCapture`) permission, required for process taps.
///
/// macOS has no public API to query this permission, so the TCC framework is loaded dynamically;
/// if that ever fails we report `.unknown` and let the first tap trigger the system prompt.
enum AudioCapturePermission: Equatable, Sendable {
    case authorized, denied, unknown
}

enum PermissionService {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    private nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var audioCapture: AudioCapturePermission {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func requestAudioCapture(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            completion(false)
            return
        }
        let request = unsafeBitCast(symbol, to: RequestFn.self)
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
