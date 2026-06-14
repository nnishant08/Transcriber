import Foundation
import UserNotifications

/// Local "done" notifications via UserNotifications. Notifications is a NEW permission: it is requested
/// lazily (onboarding or first long-running task) and every post degrades silently when not authorized.
/// Nothing here ever blocks or crashes the work it reports on.
enum Notifier {

    /// Request authorization (the system prompt appears once). Returns whether granted. Safe to call
    /// repeatedly; the OS only prompts when status is `.notDetermined`.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        guard let center = center else { return false }
        do { return try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { return false }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center = center else { return .denied }
        return await withCheckedContinuation { cont in
            center.getNotificationSettings { cont.resume(returning: $0.authorizationStatus) }
        }
    }

    /// Post a notification if (and only if) authorized — otherwise a silent no-op.
    static func notify(title: String, body: String) {
        guard let center = center else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// `UNUserNotificationCenter.current()` traps when there's no app bundle (e.g. a headless CLI
    /// self-test). Guard on a bundle identifier so the same binary's self-test modes never touch it.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
