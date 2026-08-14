import Darwin
import Foundation

/// On-disk font cache plus the in-memory index the hot path reads.
///
/// The provider callback blocks the requesting application's text layout, so the
/// lookup it performs must be a dictionary hit under a lock and nothing else —
/// no stat, no parse, no I/O of any kind.
final class Cache {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/fontfetch", isDirectory: true)

    /// How long to wait before retrying a name that could not be resolved. Stops
    /// a document full of unavailable corporate fonts from hammering the network
    /// on every reopen.
    static let negativeTTL: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var index: [String: String] = [:]      // lowercased PostScript name -> filename
    private var negative: [String: Date] = [:]     // lowercased PostScript name -> last failure

    var fontsDir: URL { Cache.root.appendingPathComponent("fonts", isDirectory: true) }
    private var indexURL: URL { Cache.root.appendingPathComponent("index.json") }
    private var negativeURL: URL { Cache.root.appendingPathComponent("negative.json") }

    init() {
        try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        sweepScratch()
        reload()
    }

    /// Clears staging directories orphaned by a fetch that was killed mid-flight.
    private func sweepScratch() {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: fontsDir, includingPropertiesForKeys: nil)
        for url in contents ?? [] where url.lastPathComponent.hasPrefix(".incoming") {
            try? FileManager.default.removeItem(at: url)
        }
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
        lock.lock()
        for name in file.postScriptNames {
            index[name.lowercased()] = filename
            negative.removeValue(forKey: name.lowercased())
        }
        lock.unlock()
        persist()
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
        if !stale.isEmpty { persist() }
        return stale.count
    }

    // MARK: - Persistence

    /// Re-reads both maps from disk. The daemon calls this on SIGHUP so a
    /// `fontfetch fetch` run in another process is picked up without a restart.
    func reload() {
        var freshIndex: [String: String] = [:]
        var freshNegative: [String: Date] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            freshIndex = decoded
        }
        if let data = try? Data(contentsOf: negativeURL),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            freshNegative = decoded.mapValues { Date(timeIntervalSince1970: $0) }
        }
        lock.lock()
        index = freshIndex
        negative = freshNegative
        lock.unlock()
    }

    /// Read-modify-write under a cross-process lock.
    ///
    /// More than one process touches these files: a `fontfetch fetch` run beside
    /// the login agent, or several concurrent fetches. Each holds its own
    /// in-memory view, so a blind overwrite silently drops whatever the others
    /// added — last writer wins and the rest of the work evaporates.
    private func persist() {
        withFileLock {
            var mergedIndex = Cache.decode([String: String].self, from: indexURL) ?? [:]
            var mergedNegative = Cache.decode([String: Double].self, from: negativeURL) ?? [:]

            lock.lock()
            let mineIndex = index
            let mineNegative = negative.mapValues { $0.timeIntervalSince1970 }
            lock.unlock()

            // Ours wins on conflict: we just verified the file on disk.
            mergedIndex.merge(mineIndex) { _, mine in mine }
            mergedNegative.merge(mineNegative) { _, mine in mine }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(mergedIndex) { try? data.write(to: indexURL) }
            if let data = try? encoder.encode(mergedNegative) { try? data.write(to: negativeURL) }

            // Adopt the merged view, so this process can serve what the others fetched.
            lock.lock()
            index = mergedIndex
            negative = mergedNegative.mapValues { Date(timeIntervalSince1970: $0) }
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
