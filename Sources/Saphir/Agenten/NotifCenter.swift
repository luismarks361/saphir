import AppKit
import UserNotifications

/// System notifications for the moments where the notch alone is not enough —
/// when the user is in another Space or another app entirely.
final class NotifCenter {
    static let shared = NotifCenter()
    private var authorized = false

    private init() {}

    func requestAuthorization() {
        // Only meaningful for a bundled, signed app; harmless otherwise.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                self?.authorized = granted
                if let error { Protokoll.info("Systemmitteilungen nicht erlaubt (\(error.localizedDescription)), Ersatzweg ueber osascript") }
            }
    }

    func postApproval(pending: PendingDecision, session: MotorSession?) {
        post(title: "Freigabe nötig · \(session?.projectName ?? "Claude")",
             body: String(pending.headline.prefix(120)),
             id: "approval-\(pending.id)")
    }

    func postNeedsInput(message: String, session: MotorSession?) {
        post(title: "\(session?.projectName ?? "Claude") braucht dich",
             body: String(message.prefix(120)),
             id: "input-\(session?.id ?? UUID().uuidString)")
    }

    func postDone(session: MotorSession?) {
        guard let session else { return }
        // Only worth a banner if the turn actually took a while.
        let duration = session.turnDuration ?? 0
        guard duration == 0 || duration > 25 else { return }
        post(title: "\(session.projectName) fertig",
             body: String((session.lastMessage ?? "Turn abgeschlossen").prefix(120)),
             id: "done-\(session.id)-\(Int(Date().timeIntervalSince1970))")
    }

    private func post(title: String, body: String, id: String) {
        guard MainActor.assumeIsolated({ AgentenOptionen.shared.mitteilungen }) else { return }

        if authorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil   // we play our own
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            postViaOSAScript(title: title, body: body)
        }
    }

    /// `UNUserNotificationCenter` refuses to deliver for an ad-hoc signed app —
    /// it wants a real Developer ID. Routing through osascript uses the system's
    /// own pre-authorised notification path instead, which needs no certificate.
    private func postViaOSAScript(title: String, body: String) {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quote(body)) with title \(quote(title))"
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardError = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            try? task.run()
        }
    }
}
