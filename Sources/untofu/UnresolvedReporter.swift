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
    /// The provider's live index, not one of our own: a freshly constructed
    /// LocalFonts has an empty dictionary until something calls refresh(), so
    /// building one here would answer "no" to every question asked of it.
    private let local: LocalFonts?
    /// Explicit QoS, and it matters. Without it the queue inherits from whoever
    /// calls `record`, which is the fetch path at `.utility` — and Dispatch
    /// grants low-QoS `asyncAfter` timers generous leeway to coalesce wakeups.
    /// Measured here: a 4-second debounce firing after 8 seconds, and once after
    /// 27. The user is looking at a wrong-looking document the whole time.
    private let queue = DispatchQueue(label: "net.elusive.untofu.unresolved",
                                      qos: .userInitiated)
    private var pending: [String] = []
    private var requester: String?
    private var requesterBundle: String?
    private var scheduled: DispatchWorkItem?

    init(preferences: Preferences, local: LocalFonts? = nil) {
        self.preferences = preferences
        self.local = local
    }

    func record(psName: String, requester: String? = nil, bundleID: String? = nil) {
        // Asked once, answered forever. Checked here rather than in the panel so
        // a suppressed name does not even hold the coalescing window open.
        guard !preferences.isSuppressed(psName) else {
            Log.debug("not reporting \(psName): the user asked not to hear about it")
            return
        }
        queue.async {
            if !self.pending.contains(psName) { self.pending.append(psName) }
            if let requester { self.requester = requester }
            if let bundleID { self.requesterBundle = bundleID }
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
        let bundle = requesterBundle
        pending = []
        requester = nil
        requesterBundle = nil

        Log.info("unresolved panel: \(names.joined(separator: ", "))"
               + "  (requested by \(who ?? "an unknown process")"
               + (bundle.map { ", \($0)" } ?? ", bundle id unavailable") + ")")
        let preferences = self.preferences
        let local = self.local
        DispatchQueue.main.async {
            MissPanel(names: names, requester: who, requesterBundle: bundle,
                      preferences: preferences, local: local).present()
        }
    }
}
