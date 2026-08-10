import Foundation
import UserNotifications

/// Best-effort user-visible notification. Running from Quill.app (the bundle
/// `quill install` assembles), notifications go through UserNotifications and
/// carry the feather icon. Running as a bare binary — dev builds, `swift run`
/// — UserNotifications would crash (no bundle proxy), so fall back to
/// osascript, which shows a generic icon but needs nothing.
func notifyUser(title: String, body: String) {
    if runningFromAppBundle {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
        )
    } else {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quoted(body)) with title \(quoted(title))"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

/// Ask for notification permission up front (daemon startup) rather than at
/// the first transcript, when the user may be mid-meeting. No-op as a bare
/// binary, cheap no-op once granted.
func requestNotificationAuthorization() {
    guard runningFromAppBundle else { return }
    UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound]
    ) { granted, _ in
        if !granted {
            FileHandle.standardError.write(Data(
                "notifications not authorized — enable in System Settings → Notifications → Quill\n"
                    .utf8
            ))
        }
    }
}

private let runningFromAppBundle = Bundle.main.bundleURL.pathExtension == "app"
