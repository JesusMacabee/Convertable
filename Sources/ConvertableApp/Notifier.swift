import Foundation
import UserNotifications
import ConvertableCore

/// macOS notifications for the moments that matter. Only works from inside a real .app bundle;
/// when run as a bare binary (`swift run`) it degrades to log lines.
final class Notifier: @unchecked Sendable {
    private var enabled = false

    func requestPermissionIfBundled() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in self.enabled = ok }
    }

    func post(title: String, body: String, id: String = UUID().uuidString) {
        guard enabled else { NSLog("[notify] %@ — %@", title, body); return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// Fires on state transitions, never on every status tick.
    func transition(from old: StatusSnapshot?, to new: StatusSnapshot) {
        guard let old else { return }
        if old.state == .converting, new.state == .batchComplete {
            post(title: "Batch complete", body: "Backlog: \(new.library.backlogAlbums) albums, \(ByteCount.string(new.library.backlogBytes)) remaining.", id: "batch-complete")
        }
        if old.volumeAvailable, !new.volumeAvailable {
            post(title: "Source volume unavailable", body: new.volume, id: "volume")
        }
        if !old.volumeAvailable, new.volumeAvailable {
            post(title: "Source volume is back", body: new.volume, id: "volume-back")
        }
        if old.musicImportDisabled == nil, let reason = new.musicImportDisabled {
            post(title: "Music imports paused", body: reason, id: "music-disabled")
        }
        let oldIDs = Set(old.alerts.map(\.id))
        for a in new.alerts where !oldIDs.contains(a.id) && a.level == "error" && a.id != "volume" && a.id != "music-disabled" {
            post(title: "Convertable needs attention", body: a.message, id: a.id)
        }
    }
}
