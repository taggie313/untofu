import Foundation

/// Coalesces a burst of fetches into one transient notification.
///
/// Deliberately posts via `osascript display notification` rather than
/// UserNotifications: UNUserNotificationCenter requires a bundled, signed
/// application, and becoming an app would put fontfetch in the Dock or the menu
/// bar permanently. It should be invisible until the moment it has something to
/// say, which is a handful of times in a machine's life.
///
/// The cost of that choice is identity: the banner is attributed to whichever
/// bundle osascript posts under, not to fontfetch. That seemed the better trade
/// against a permanent menu-bar resident.
final class Notifier {
    /// A document with several missing fonts produces a burst of requests. Wait
    /// for things to go quiet, then send one summary rather than one per font.
    static let quietPeriod: TimeInterval = 3.0

    private let queue = DispatchQueue(label: "net.elusive.fontfetch.notify")
    private var pending: [String] = []
    private var scheduled: DispatchWorkItem?

    /// Records a fetched family. All state is confined to `queue`, so there are
    /// no locks here.
    func record(family: String) {
        queue.async {
            if !self.pending.contains(family) { self.pending.append(family) }
            self.scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.scheduled = work
            self.queue.asyncAfter(deadline: .now() + Notifier.quietPeriod, execute: work)
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let families = pending
        pending = []

        let count = families.count
        let subtitle = count == 1 ? "Fetched a missing font" : "Fetched \(count) missing fonts"
        // The document that triggered this already rendered with a substitute —
        // the fetch is asynchronous by design — so the reopen hint is the most
        // useful thing the banner can say.
        let body = "\(list(families)) — reopen the document to see \(count == 1 ? "it" : "them")."
        Log.info("notified: \(subtitle) — \(list(families))")
        Notifier.post(title: "fontfetch", subtitle: subtitle, body: body)
    }

    private func list(_ families: [String]) -> String {
        switch families.count {
        case 1: return families[0]
        case 2: return "\(families[0]) and \(families[1])"
        case 3...4: return families.dropLast().joined(separator: ", ") + ", and \(families.last!)"
        default: return families.prefix(3).joined(separator: ", ") + ", and \(families.count - 3) more"
        }
    }

    static func post(title: String, subtitle: String, body: String) {
        let script = "display notification \"\(escape(body))\" "
                   + "with title \"\(escape(title))\" subtitle \"\(escape(subtitle))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Log.debug("could not post notification: \(error.localizedDescription)")
        }
    }

    /// Font family names are attacker-influenced only to the degree that a
    /// document author picks them, but they still land inside an AppleScript
    /// string literal, so quote and backslash have to go.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
