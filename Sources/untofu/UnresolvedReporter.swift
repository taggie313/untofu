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
    /// Each missing name with the requester that asked for it, so the two can
    /// never drift apart while the window is open.
    private var pending: [(name: String, requester: String?, bundle: String?)] = []
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
            // Kept together. Names accumulated while the requester was
            // overwritten by each call, so a panel headed by the first font
            // named the app that asked for the LAST one — two applications
            // missing different fonts inside the four-second window produced one
            // panel confidently attributing both to whichever asked second, and
            // a miss report carrying that same wrong bundle id.
            if !self.pending.contains(where: { $0.name == psName }) {
                self.pending.append((name: psName, requester: requester, bundle: bundleID))
            }
            self.scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.scheduled = work
            self.queue.asyncAfter(deadline: .now() + UnresolvedReporter.quietPeriod, execute: work)
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []

        let names = batch.map(\.name)
        // The panel is headed by the first name, so the report and the "who
        // asked" line must belong to that one.
        let bundle = batch[0].bundle
        // Only claim an application when they all agree. Two apps inside one
        // window is a real case, and naming either of them would be a guess
        // presented as a fact.
        let requesters = Set(batch.compactMap(\.requester))
        let who = requesters.count == 1 ? requesters.first : nil

        let attribution: String
        if let who {
            attribution = who
        } else if requesters.isEmpty {
            attribution = "an unknown process"
        } else {
            attribution = "\(requesters.count) different applications"
        }
        Log.info("unresolved panel: \(names.joined(separator: ", "))"
               + "  (requested by \(attribution)"
               + (bundle.map { ", \($0)" } ?? ", bundle id unavailable") + ")")
        let preferences = self.preferences
        let local = self.local
        DispatchQueue.main.async {
            MissPanel(names: names, requester: who, requesterBundle: bundle,
                      preferences: preferences, local: local).present()
        }
    }
}
