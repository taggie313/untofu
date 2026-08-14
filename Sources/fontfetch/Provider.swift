import CFontProvider
import Darwin
import Foundation

/// Owns the CoreText hook and splits work across the two paths that matter:
/// an in-memory cache hit answered synchronously, and everything else pushed to
/// a background queue so the callback returns immediately.
final class Provider {
    private let cache: Cache
    private let notifier: Notifier?
    private let queue = DispatchQueue(label: "net.elusive.fontfetch.resolve", qos: .utility)
    private let inFlightLock = NSLock()
    private var inFlight = Set<String>()

    init(cache: Cache, notifier: Notifier? = nil) {
        self.cache = cache
        self.notifier = notifier
    }

    func start() -> Bool {
        ff_provider_start(requestThunk, Unmanaged.passUnretained(self).toOpaque())
    }

    func run() { ff_provider_run() }
    func stop() { ff_provider_stop() }

    /// The hot path. Runs on the provider's runloop with the requesting
    /// application's text layout blocked behind it.
    fileprivate func handle(psName: String, pid: pid_t) -> String? {
        if let path = cache.path(for: psName) {
            Log.info("hit  \(psName)  (pid \(pid))")
            return path
        }
        Log.info("miss \(psName)  (pid \(pid)) — resolving in background")
        enqueue(psName)
        return nil
    }

    /// Schedules a fetch, collapsing duplicates. A document with the same missing
    /// font on forty slides produces one request storm; without this, forty
    /// concurrent downloads.
    private func enqueue(_ psName: String) {
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
            Fetcher.fetch(psName: psName, into: self.cache,
                          notify: { [weak self] in self?.notifier?.record(family: $0) })
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
