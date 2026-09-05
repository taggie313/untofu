import CFontProvider
import Darwin
import Foundation

/// Owns the CoreText hook and splits work across the two paths that matter:
/// an in-memory cache hit answered synchronously, and everything else pushed to
/// a background queue so the callback returns immediately.
final class Provider {
    private let cache: Cache
    private let local: LocalFonts?
    private let notifier: Notifier?
    private let reporter: UnresolvedReporter?
    /// How many fetches may be in flight at once.
    ///
    /// Four. A fetch is almost entirely blocking round trips — up to two
    /// candidates across three license directories to list, then up to eight
    /// files to download, each a semaphore wait on a URLSession task — so it is
    /// latency, not CPU, and throughput scales with width until the network
    /// saturates. Serially, a document with eight missing fonts also defeats the
    /// Notifier's three-second debounce by construction: the successes arrive
    /// too far apart to coalesce, so the user gets a trickle of dialogs instead
    /// of one saying "Fetched 8 missing fonts".
    ///
    /// Four also bounds the waste when GitHub says stop. At the instant one
    /// worker sees a 403, at most three others already have a request in flight;
    /// every worker after that finds the pause armed and returns without asking.
    /// The over-spend is the width, not the number of missing fonts.
    static let maxConcurrentFetches = 4

    /// An OperationQueue rather than a concurrent DispatchQueue, and the
    /// distinction matters here. These bodies block on semaphores, and GCD
    /// answers a blocked worker by starting another thread — so a deck with
    /// twenty distinct missing fonts would park twenty threads waiting on the
    /// network. OperationQueue runs at most `maxConcurrentOperationCount` at a
    /// time and leaves the rest as objects, not threads.
    /// Counts what this agent has done, for `untofu stats` and the one line the
    /// panels carry. Nil for the short-lived probe in `status`, which would
    /// otherwise record serves it never performed.
    let stats: Stats?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "net.elusive.untofu.resolve"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = Provider.maxConcurrentFetches
        return q
    }()
    private let inFlightLock = NSLock()
    private var inFlight = Set<String>()

    /// The most recent queued operation per font family.
    ///
    /// `inFlight` collapses the same NAME arriving forty times, which a document
    /// does constantly. It does nothing for two *different* names of one family,
    /// and those are just as common: a deck using Lato regular and bold asks for
    /// Lato-Regular and Lato-Bold, which are different keys resolving to the
    /// same `ofl/lato` — so each ran the whole listing-and-download sequence,
    /// spending the 60-requests-an-hour budget several times over on one family.
    ///
    /// The second arrival is not dropped: dropping it would cost the user a
    /// second reopen of their document. It is made to run *after* the first,
    /// which usually finds the answer already in the cache and returns without
    /// asking GitHub anything.
    private var familyOperations: [String: Operation] = [:]

    /// When false, a browser's cache misses are declined rather than fetched.
    private let fetchForBrowsers: Bool

    init(cache: Cache, local: LocalFonts? = nil,
         notifier: Notifier? = nil, reporter: UnresolvedReporter? = nil,
         fetchForBrowsers: Bool = false, stats: Stats? = nil) {
        self.stats = stats
        self.cache = cache
        self.local = local
        self.notifier = notifier
        self.reporter = reporter
        self.fetchForBrowsers = fetchForBrowsers
    }

    func start() -> Bool {
        ff_provider_start(requestThunk, Unmanaged.passUnretained(self).toOpaque())
    }

    func run() { ff_provider_run() }

    /// Registers the source on the current runloop without running it, for a
    /// caller that runs the main runloop itself.
    func attach() { ff_provider_attach() }
    func stop() { ff_provider_stop() }

    /// The hot path. Runs on the provider's runloop with the requesting
    /// application's text layout blocked behind it.
    fileprivate func handle(psName rawName: String, pid: pid_t) -> String? {
        // CoreText hands over an empty NSFontNameAttribute now and again — seen
        // in the wild as `miss   (pid 57443)`. Nothing downstream can do
        // anything with it, but left unchecked it still reserves an in-flight
        // slot and spawns a subprocess to name the requesting app.
        guard let psName = Resolver.normalized(rawName) else {
            Log.debug("ignoring an unusable font name from pid \(pid): \(rawName.prefix(80))")
            return nil
        }
        if psName != rawName {
            Log.info("normalised \(rawName.prefix(60)) -> \(psName)  (pid \(pid))")
        }

        if let path = cache.path(for: psName) {
            Log.info("hit  \(psName)  (pid \(pid))")
            stats?.record(servedCache: 1)
            return path
        }

        // A font already on this disk but registered to nobody. Served to
        // everyone including browsers: nothing is fetched, nothing leaves the
        // machine, and the file was readable by the requesting process anyway.
        //
        // This is the only path that answers in time. A fetch cannot help the
        // layout that triggered it — the request has to be declined while the
        // download runs — but the local index is built before the first request
        // arrives, so the document renders correctly the first time.
        if let path = local?.path(for: psName) {
            Log.info("local \(psName)  (pid \(pid)) <- \(local?.origin(ofPath: path) ?? "disk")")
            stats?.record(servedLocal: 1)
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

        // The most specific slug only — `familyCandidates` first element, which
        // is what `lookupSlugs` itself starts from. Being specific means this can
        // miss a pairing, which only costs the duplicate work it was already
        // doing; it can never merge two genuinely different families.
        let family = Resolver.familyCandidates(for: psName).first ?? key

        let work = BlockOperation { [weak self] in
            guard let self else { return }

            // Whatever ran ahead of us may already have supplied this exact
            // name: one download indexes every face it answers to, so a sibling
            // fetch usually makes this one unnecessary. Re-checked here rather
            // than in handle(), which decided to enqueue before the queue ran.
            if self.cache.path(for: psName) != nil {
                Log.debug("\(psName) arrived while queued — a sibling fetch supplied it")
                self.finish(key: key, family: family)
                return
            }
            // Resolved here rather than in handle(): naming the app costs a
            // subprocess, which must stay off the blocking path.
            let app = Notifier.appName(for: pid)
            // Resolved HERE, not when the report is built. The panel debounces
            // for four seconds and then waits for a person to press a button —
            // measured at 9 to 65 seconds after the request in the reports
            // received so far — and a requester can be gone in two. Worse than
            // losing the name: pids are recycled, so asking the system minutes
            // later can confidently name a completely unrelated application.
            let bundle = RequesterPolicy.bundleIdentifier(pid)
            Log.debug("requester for \(psName): \(app ?? "unknown") "
                    + "[\(bundle ?? "no bundle id")] (pid \(pid))")
            Fetcher.fetch(psName: psName, into: self.cache,
                          observer: Fetcher.Observer(
                              resolved: { [weak self] in
                                  self?.stats?.record(fetched: 1)
                                  self?.notifier?.record(family: $0, app: app)
                              },
                              unresolved: { [weak self] in
                                  self?.stats?.record(unresolved: 1)
                                  self?.reporter?.record(psName: $0, requester: app, bundleID: bundle)
                              }))
            self.finish(key: key, family: family)
        }

        // Same family: run behind whatever is already queued for it rather than
        // beside it. Different families still run four wide.
        inFlightLock.lock()
        if let previous = familyOperations[family], !previous.isFinished {
            work.addDependency(previous)
        }
        familyOperations[family] = work
        inFlightLock.unlock()

        queue.addOperation(work)
    }

    /// Releases the in-flight name and forgets the family's operation if it was
    /// the last one queued for it.
    private func finish(key: String, family: String) {
        inFlightLock.lock()
        inFlight.remove(key)
        if familyOperations[family]?.isFinished ?? true { familyOperations[family] = nil }
        inFlightLock.unlock()
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
