import Darwin
import Foundation

/// On-disk font cache plus the in-memory index the hot path reads.
///
/// The provider callback blocks the requesting application's text layout, so the
/// lookup it performs must be a dictionary hit under a lock and nothing else —
/// no stat, no parse, no I/O of any kind.
final class Cache {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/untofu", isDirectory: true)

    /// How long to wait before retrying a name that could not be resolved. Stops
    /// a document full of unavailable corporate fonts from hammering the network
    /// on every reopen.
    static let negativeTTL: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var index: [String: String] = [:]      // lowercased PostScript name -> filename
    private var negative: [String: Date] = [:]     // lowercased PostScript name -> last failure

    /// What this process has added but not yet written out.
    ///
    /// persist() has to satisfy two things that pull against each other: it must
    /// not lose an entry another thread added while it was writing, and it must
    /// not resurrect an entry that is deliberately gone from disk. Publishing
    /// the whole in-memory map solves the first and breaks the second — a
    /// running agent would quietly restore an index full of dead paths after
    /// someone cleared the cache directory. Publishing only what is pending
    /// solves both: a concurrent add is still pending, so either this call
    /// carries it or its own persist does, while everything already published
    /// takes its truth from the file.
    private var pendingIndex: [String: String] = [:]
    private var pendingNegative: [String: Double] = [:]

    var fontsDir: URL { Cache.root.appendingPathComponent("fonts", isDirectory: true) }
    private var indexURL: URL { Cache.root.appendingPathComponent("index.json") }
    private var negativeURL: URL { Cache.root.appendingPathComponent("negative.json") }

    init() {
        try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        sweepScratch()
        reload()
    }

    /// Name for a fetch's staging directory, carrying the pid that owns it.
    ///
    /// The pid is the whole point. Staging used to be `.incoming-<uuid>`, which
    /// said nothing about whether anyone was still using it, so the sweep below
    /// could only delete all of them or none.
    static func scratchName() -> String { ".incoming-\(getpid())-\(UUID().uuidString)" }

    /// Clears staging directories orphaned by a fetch that died mid-flight —
    /// and *only* those.
    ///
    /// This runs from `init`, so it runs in every `untofu` invocation, including
    /// `--version`. It used to delete every `.incoming-*` directory it found,
    /// which meant typing `untofu status` while the agent was downloading a font
    /// deleted the agent's staging area out from under it. Every subsequent
    /// download in that fetch failed silently, the loop fell through to
    /// `markUnresolved`, and the user was told a perfectly available Google font
    /// was "a commercial or private font" — then not told again for six hours,
    /// because the failure was cached.
    ///
    /// So a directory is only swept when the process that made it is gone.
    /// `kill(pid, 0)` is the cheap liveness test; ESRCH means no such process.
    private func sweepScratch() {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: fontsDir, includingPropertiesForKeys: nil)
        for url in contents ?? [] where url.lastPathComponent.hasPrefix(".incoming") {
            guard let owner = Cache.scratchOwner(url.lastPathComponent) else {
                // Unparseable, so from a version that did not stamp the pid.
                // Nothing is using it — that scheme is gone — so it is safe.
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard !Cache.processIsAlive(owner) else { continue }
            Log.debug("sweeping abandoned staging from pid \(owner)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// pid out of `.incoming-<pid>-<uuid>`, or nil for the old unstamped form.
    private static func scratchOwner(_ name: String) -> pid_t? {
        let parts = name.split(separator: "-")
        guard parts.count >= 3, let pid = pid_t(parts[1]) else { return nil }
        return pid
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        // 0 means it exists and we may signal it; EPERM means it exists and we
        // may not — either way it is alive. Only ESRCH means gone.
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Hot path

    /// Absolute path of a cached file answering to `psName`, or nil.
    ///
    /// Deliberately does not check the file still exists — that would be a stat
    /// on the blocking path. A file deleted behind our back yields a URL CoreText
    /// rejects, which degrades to the normal missing-font behaviour. `verify()`
    /// cleans up such entries out of band.
    func path(for psName: String) -> String? {
        let key = psName.lowercased()
        lock.lock(); defer { lock.unlock() }
        guard let name = index[key] else { return nil }
        return fontsDir.appendingPathComponent(name).path
    }

    // MARK: - Bookkeeping

    /// Records every face in a file, so fetching one weight satisfies its siblings.
    func record(_ file: FontFile) {
        let filename = file.url.lastPathComponent
        var cleared = Set<String>()
        lock.lock()
        for name in file.postScriptNames {
            index[name.lowercased()] = filename
            pendingIndex[name.lowercased()] = filename
            if negative.removeValue(forKey: name.lowercased()) != nil {
                cleared.insert(name.lowercased())
            }
        }
        lock.unlock()
        // Same reason as verify(): clearing a negative entry is a deletion, and
        // a merge cannot carry one. Harmless in practice today — a name in the
        // index is answered before the negative cache is ever consulted — but
        // it left a permanent "this failed" record for a font that succeeded.
        persist(removingNegativeKeys: cleared)
    }

    func shouldAttempt(_ psName: String) -> Bool {
        let key = psName.lowercased()
        lock.lock(); defer { lock.unlock() }
        guard let last = negative[key] else { return true }
        return Date().timeIntervalSince(last) > Cache.negativeTTL
    }

    func markUnresolved(_ psName: String) {
        lock.lock()
        negative[psName.lowercased()] = Date()
        pendingNegative[psName.lowercased()] = Date().timeIntervalSince1970
        lock.unlock()
        persist()
    }

    var entries: [(psName: String, file: String)] {
        lock.lock(); defer { lock.unlock() }
        return index.map { (psName: $0.key, file: $0.value) }.sorted { $0.psName < $1.psName }
    }

    var unresolvedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return negative.keys.sorted()
    }

    /// Drops index entries whose backing file has gone away.
    @discardableResult
    func verify() -> Int {
        lock.lock()
        let stale = index.filter { !FileManager.default.fileExists(
            atPath: fontsDir.appendingPathComponent($0.value).path) }
        for key in stale.keys { index.removeValue(forKey: key) }
        lock.unlock()
        // The removals have to be named explicitly: persist merges this
        // process's view *over* what is on disk, and a key we deleted is simply
        // a key we do not have — indistinguishable from one we never knew about.
        if !stale.isEmpty { persist(removingIndexKeys: Set(stale.keys)) }
        return stale.count
    }

    // MARK: - Persistence

    /// Re-reads both maps from disk. The daemon calls this on SIGHUP so a
    /// `untofu fetch` run in another process is picked up without a restart.
    /// Re-reads both maps, keeping what it already has for anything it cannot
    /// read.
    ///
    /// The "cannot read" case used to fall through to an empty dictionary and
    /// then assign it, so one unreadable file emptied the live index and the
    /// agent quietly stopped serving every font it had cached. A file that will
    /// not decode is a reason to keep the last good view and say so, never a
    /// reason to conclude the cache is empty — the same mistake as treating a
    /// failed lookup as proof a font does not exist.
    func reload() {
        let freshIndex = Cache.decode([String: String].self, from: indexURL)
        let freshNegative = Cache.decode([String: Double].self, from: negativeURL)

        if freshIndex == nil, FileManager.default.fileExists(atPath: indexURL.path) {
            Log.warn("\(indexURL.lastPathComponent) could not be read; keeping the "
                   + "\(entries.count) face(s) already indexed")
        }

        lock.lock()
        if let freshIndex { index = freshIndex }
        if let freshNegative { negative = freshNegative.mapValues { Date(timeIntervalSince1970: $0) } }
        lock.unlock()
    }

    /// Read-modify-write under a cross-process lock.
    ///
    /// More than one process touches these files: a `untofu fetch` run beside
    /// the login agent, or several concurrent fetches. Each holds its own
    /// in-memory view, so a blind overwrite silently drops whatever the others
    /// added — last writer wins and the rest of the work evaporates.
    private func persist(removingIndexKeys removedIndex: Set<String> = [],
                         removingNegativeKeys removedNegative: Set<String> = []) {
        withFileLock {
            var mergedIndex = Cache.decode([String: String].self, from: indexURL) ?? [:]
            var mergedNegative = Cache.decode([String: Double].self, from: negativeURL) ?? [:]

            // Only what has not been published yet, and clear it in the same
            // critical section so a concurrent add either lands in this batch or
            // stays pending for its own.
            lock.lock()
            let mineIndex = pendingIndex
            let mineNegative = pendingNegative
            pendingIndex = [:]
            pendingNegative = [:]
            lock.unlock()

            // Ours wins on conflict: we just verified the file on disk.
            mergedIndex.merge(mineIndex) { _, mine in mine }
            mergedNegative.merge(mineNegative) { _, mine in mine }

            // Deletions, which the merge above cannot express. Without this,
            // `untofu verify` printed "dropped 62 stale entries", put them
            // straight back from disk, and printed the identical 62 the next
            // time it ran — a command that reported success and did nothing,
            // guarded by a test that only checked it said the word "dropped".
            for key in removedIndex { mergedIndex.removeValue(forKey: key) }
            for key in removedNegative { mergedNegative.removeValue(forKey: key) }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // .atomic, because these are read by other processes — and, since
            // 0.4.3, by this one's own file watcher every two seconds. A plain
            // write truncates in place, so a reader landing mid-write gets half
            // a JSON document, which reload() below used to turn into an empty
            // index: the agent would stop serving every cached font it had.
            if let data = try? encoder.encode(mergedIndex) {
                try? data.write(to: indexURL, options: .atomic)
            }
            if let data = try? encoder.encode(mergedNegative) {
                try? data.write(to: negativeURL, options: .atomic)
            }

            // Adopt what the other writers contributed WITHOUT discarding what
            // this process added while the write was in flight.
            //
            // This was `index = mergedIndex`, which is a lost update. The
            // snapshot above is taken inside the flock, but another thread can
            // add an entry between that snapshot and this line, and the
            // assignment threw it away — first from memory, and then from disk
            // too, because that thread's own persist() would snapshot the map we
            // had just emptied for it. The font ended up sitting in fontsDir
            // indexed under nothing, while the user had already been told it was
            // fetched and to reopen their document.
            //
            // Harmless while the resolve queue was serial. It becomes the normal
            // case the moment more than one fetch runs at a time, which is why it
            // is fixed before widening rather than after.
            // Adopt the file as the truth, then put back anything that became
            // pending while the write was in flight — that, and only that, is
            // what this process knows and the file does not.
            lock.lock()
            index = mergedIndex
            negative = mergedNegative.mapValues { Date(timeIntervalSince1970: $0) }
            for (key, value) in pendingIndex { index[key] = value }
            for (key, value) in pendingNegative { negative[key] = Date(timeIntervalSince1970: value) }
            lock.unlock()
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private var lockURL: URL { Cache.root.appendingPathComponent("index.lock") }

    private func withFileLock(_ body: () -> Void) {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { body(); return }   // no lock is better than no write
        flock(fd, LOCK_EX)
        body()
        flock(fd, LOCK_UN)
        close(fd)
    }
}
