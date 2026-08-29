import AppKit
import Darwin
import Foundation

/// Tells the user when a font could not be found, and offers somewhere to look.
///
/// A silent failure is the one case where the user genuinely needs information:
/// the document has already substituted something, untofu cannot help, and
/// nothing on screen explains why. So this is the one place the tool is allowed
/// to interrupt.
///
/// Coalesced — a document referencing eight private corporate fonts produces one
/// panel, not eight. The negative cache then keeps it quiet for six hours per
/// name, and `Preferences.suppressedNames` keeps it quiet forever for names the
/// user has said they do not want to hear about again.
final class UnresolvedReporter {
    /// Slightly longer than the success banner's: a miss costs a full round of
    /// candidate lookups, so misses trickle in more slowly than hits.
    static let quietPeriod: TimeInterval = 4.0

    private let preferences: Preferences
    /// Explicit QoS, and it matters. Without it the queue inherits from whoever
    /// calls `record`, which is the fetch path at `.utility` — and Dispatch
    /// grants low-QoS `asyncAfter` timers generous leeway to coalesce wakeups.
    /// Measured here: a 4-second debounce firing after 8 seconds, and once after
    /// 27. The user is looking at a wrong-looking document the whole time.
    private let queue = DispatchQueue(label: "net.elusive.untofu.unresolved",
                                      qos: .userInitiated)
    private var pending: [String] = []
    private var requester: String?
    private var requesterPID: pid_t?
    private var scheduled: DispatchWorkItem?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func record(psName: String, requester: String? = nil, pid: pid_t? = nil) {
        // Asked once, answered forever. Checked here rather than in the panel so
        // a suppressed name does not even hold the coalescing window open.
        guard !preferences.isSuppressed(psName) else {
            Log.debug("not reporting \(psName): the user asked not to hear about it")
            return
        }
        queue.async {
            if !self.pending.contains(psName) { self.pending.append(psName) }
            if let requester { self.requester = requester }
            if let pid { self.requesterPID = pid }
            self.scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.scheduled = work
            self.queue.asyncAfter(deadline: .now() + UnresolvedReporter.quietPeriod, execute: work)
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let names = pending
        let who = requester
        let pid = requesterPID
        pending = []
        requester = nil
        requesterPID = nil

        Log.info("unresolved panel: \(names.joined(separator: ", "))")
        let preferences = self.preferences
        DispatchQueue.main.async {
            MissPanel(names: names, requester: who, requesterPID: pid,
                      preferences: preferences).present()
        }
    }
}
