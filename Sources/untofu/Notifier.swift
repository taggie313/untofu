import Foundation

/// Announces successful fetches, coalescing a burst into one message.
///
/// Defaults to a dialog that must be dismissed rather than a transient banner:
/// the whole point of the message is that the document on screen is still
/// showing a substitute and needs reopening, which is easy to miss if the
/// notification quietly expires. `--banner` restores the transient style.
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
            let body = "\(headline)\n\n" + families.map { "  •  \($0)" }.joined(separator: "\n")
                     + "\n\n\(reopen)"
            Shell.osascript("""
            display dialog "\(Shell.escape(body))" with title "untofu" \
            buttons {"OK"} default button "OK" with icon note
            """)
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
