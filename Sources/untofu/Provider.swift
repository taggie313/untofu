import CFontProvider
import Darwin
import Foundation

/// Owns the CoreText hook and splits work across the two paths that matter:
/// an in-memory cache hit answered synchronously, and everything else pushed to
/// a background queue so the callback returns immediately.
final class Provider {
    private let cache: Cache
    private let notifier: Notifier?
    private let reporter: UnresolvedReporter?
    private let queue = DispatchQueue(label: "net.elusive.untofu.resolve", qos: .utility)
    private let inFlightLock = NSLock()
    private var inFlight = Set<String>()

    /// When false, a browser's cache misses are declined rather than fetched.
    private let fetchForBrowsers: Bool

    init(cache: Cache, notifier: Notifier? = nil, reporter: UnresolvedReporter? = nil,
         fetchForBrowsers: Bool = false) {
        self.cache = cache
        self.notifier = notifier
        self.reporter = reporter
        self.fetchForBrowsers = fetchForBrowsers
    }

    func start() -> Bool {
        ff_provider_start(requestThunk, Unmanaged.passUnretained(self).toOpaque())
    }

    func run() { ff_provider_run() }
    func stop() { ff_provider_stop() }

    /// The hot path. Runs on the provider's runloop with the requesting
    /// application's text layout blocked behind it.
    fileprivate func handle(psName: String, pid: pid_t) -> String? {
        // CoreText hands over an empty NSFontNameAttribute now and again — seen
        // in the wild as `miss   (pid 57443)`. Nothing downstream can do
        // anything with it, but left unchecked it still reserves an in-flight
        // slot and spawns a subprocess to name the requesting app.
        guard !psName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.debug("ignoring an empty font name from pid \(pid)")
            return nil
        }

        if let path = cache.path(for: psName) {
            Log.info("hit  \(psName)  (pid \(pid))")
            return path
        }

        // Policy is consulted only on a miss. A hit costs nothing, touches no
        // network and leaks nothing, so it is served to everyone — browsers
        // included, which makes pages render slightly better for free.
        if !fetchForBrowsers, RequesterPolicy.forProcess(pid) == .serveFromCacheOnly {
            Log.debug("miss \(psName) (pid \(pid)) — declined, "
                    + "\(RequesterPolicy.displayName(pid) ?? "requester") is a browser")
            return nil
        }

        Log.info("miss \(psName)  (pid \(pid)) — resolving in background")
        enqueue(psName, pid: pid)
        return nil
    }

    /// Schedules a fetch, collapsing duplicates. A document with the same missing
    /// font on forty slides produces one request storm; without this, forty
    /// concurrent downloads.
    private func enqueue(_ psName: String, pid: pid_t) {
        guard cache.shouldAttempt(psName) else {
            Log.debug("skipping \(psName): failed recently")
            return
        }
        let key = psName.lowercased()
        inFlightLock.lock()
        let isNew = inFlight.insert(key).inserted
        inFlightLock.unlock()
        guard isNew else { return }

        queue.async { [weak self] in
            guard let self else { return }
            // Resolved here rather than in handle(): naming the app costs a
            // subprocess, which must stay off the blocking path.
            let app = Notifier.appName(for: pid)
            Fetcher.fetch(psName: psName, into: self.cache,
                          observer: Fetcher.Observer(
                              resolved: { [weak self] in self?.notifier?.record(family: $0, app: app) },
                              unresolved: { [weak self] in self?.reporter?.record(psName: $0) }))
            self.inFlightLock.lock()
            self.inFlight.remove(key)
            self.inFlightLock.unlock()
        }
    }
}

/// C function pointers cannot capture, so the Provider arrives via the context
/// pointer that was handed to ff_provider_start.
private let requestThunk: FFRequestHandler = { psNamePtr, pid, context, outPath, capacity in
    guard let psNamePtr, let context, let outPath else { return 0 }
    let provider = Unmanaged<Provider>.fromOpaque(context).takeUnretainedValue()
    guard let path = provider.handle(psName: String(cString: psNamePtr), pid: pid) else { return 0 }
    guard path.utf8.count + 1 <= capacity else { return 0 }
    path.withCString { _ = strlcpy(outPath, $0, capacity) }
    return 1
}
