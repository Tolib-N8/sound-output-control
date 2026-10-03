import AppKit
import ServiceManagement
import UserNotifications

enum NotificationService {
    static func requestAuthorization(_ completion: (@Sendable (Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion?(granted)
        }
    }

    static func status(_ completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { completion($0.authorizationStatus) }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            audioLog.error("Login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
