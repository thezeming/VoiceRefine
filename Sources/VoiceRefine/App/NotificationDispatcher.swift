import Foundation
import os
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` so the pipeline can
/// raise user-visible errors without taking a hard dependency on
/// UserNotifications everywhere. Silent-fails if notifications are
/// denied — we never want a missing toast to escalate to something
/// worse.
enum NotificationDispatcher {
    // OSAllocatedUnfairLock is Swift-Sendable (it is itself a value type
    // wrapping an os_unfair_lock_t). Replaces the old DispatchQueue.sync
    // pattern which had a broken guard-inside-closure bug in the original.
    private static let authState = OSAllocatedUnfairLock(initialState: (authorized: false, didRequest: false))

    static func requestAuthorization() {
        let shouldRequest = authState.withLock { state -> Bool in
            guard !state.didRequest else { return false }
            state.didRequest = true
            return true
        }
        guard shouldRequest else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            authState.withLock { $0.authorized = granted }
            if let error {
                NSLog("VoiceRefine: notification auth failed: \(error)")
            }
        }
    }

    static func postError(title: String, message: String) {
        post(title: title, message: message, sound: .default)
    }

    static func postInfo(title: String, message: String) {
        post(title: title, message: message, sound: nil)
    }

    private static func post(title: String, message: String, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if let sound { content.sound = sound }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("VoiceRefine: notification post failed — \(title): \(error)")
            }
        }
    }
}
