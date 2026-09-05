import AppKit
import Foundation

/// Announces successful fetches, coalescing a burst into one message.
///
/// Defaults to a dialog that must be dismissed rather than a transient banner:
/// the whole point of the message is that the document on screen is still
/// showing a substitute and needs reopening, which is easy to miss if the
/// notification quietly expires. `--banner` restores the transient style.
///
/// The dialog is AppKit, like the unresolved panel. It was the last surface
/// still going through `osascript display dialog`, which showed: a generic blue
/// folder for an icon, attribution to Script Editor rather than to untofu, and —
/// because osascript is a separate process — a dialog that outlived the agent
/// that raised it. Running modal is safe here despite the provider living on the
/// same runloop, because the font-request source is registered in the *common*
/// modes and so keeps firing while a modal session is up.
final class Notifier {
    enum Style {
        /// A dialog with an OK button. Stays until acknowledged.
        case dialog
        /// A transient notification banner. Posted via `osascript display
        /// notification`, so it is attributed to whichever bundle osascript runs
        /// under rather than to untofu.
        case banner
    }

    /// A document with several missing fonts produces a burst of requests. Wait
    /// for things to go quiet, then send one summary rather than one per font.
    static let quietPeriod: TimeInterval = 3.0

    private let style: Style
    /// Explicit QoS for the same reason as the unresolved reporter's: inheriting
    /// `.utility` from the fetch path lets Dispatch coalesce this debounce timer
    /// into a much later wakeup.
    private let queue = DispatchQueue(label: "net.elusive.untofu.notify",
                                      qos: .userInitiated)
    private var pending: [String] = []
    private var apps = Set<String>()
    private var scheduled: DispatchWorkItem?

    init(style: Style = .dialog) { self.style = style }

    /// Records a fetched family and the app that asked for it. All state is
    /// confined to `queue`, so there are no locks here.
    func record(family: String, app: String?) {
        queue.async {
            if !self.pending.contains(family) { self.pending.append(family) }
            if let app { self.apps.insert(app) }
            self.scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.scheduled = work
            self.queue.asyncAfter(deadline: .now() + Notifier.quietPeriod, execute: work)
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let families = pending
        let requesters = apps
        pending = []
        apps = []

        let count = families.count
        let headline = count == 1 ? "Fetched a missing font" : "Fetched \(count) missing fonts"
        Log.info("notified: \(headline) — \(families.joined(separator: ", "))")

        // The document that triggered this already rendered with a substitute —
        // the fetch is asynchronous by design — so the reopen hint is the most
        // useful thing the message can carry.
        let where_ = requesters.count == 1 ? " in \(requesters.first!)" : ""
        let reopen = "Reopen your document\(where_) to see \(count == 1 ? "it" : "them")."

        switch style {
        case .banner:
            Notifier.post(title: "untofu", subtitle: headline,
                          body: "\(sentence(families)) — \(reopen)")
        case .dialog:
            let list = families.map { "•  \($0)" }.joined(separator: "\n")
            // The running total, in a window that is already open. This tool is
            // deliberately invisible, which leaves a user with no way to know it
            // has ever done anything; the answer is to say so at the moment it
            // just did, not to invent a menu bar item or a nagging window.
            let total = Stats.summaryLine().map { "\n\n\($0)" } ?? ""
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = headline
                alert.informativeText = "\(list)\n\n\(reopen)\(total)"
                alert.alertStyle = .informational
                alert.icon = Icon.image()
                alert.addButton(withTitle: "OK")
                // .accessory processes can raise a modal behind the frontmost
                // window, which for a message about the document you are looking
                // at would be worse than useless.
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func sentence(_ families: [String]) -> String {
        switch families.count {
        case 1: return families[0]
        case 2: return "\(families[0]) and \(families[1])"
        case 3...4: return families.dropLast().joined(separator: ", ") + ", and \(families.last!)"
        default: return families.prefix(3).joined(separator: ", ") + ", and \(families.count - 3) more"
        }
    }

    static func post(title: String, subtitle: String, body: String) {
        Shell.osascript("""
        display notification "\(Shell.escape(body))" with title "\(Shell.escape(title))" \
        subtitle "\(Shell.escape(subtitle))"
        """)
    }

    /// Best-effort friendly name for the process that asked for the font.
    static func appName(for pid: pid_t) -> String? {
        RequesterPolicy.displayName(pid)
    }
}
