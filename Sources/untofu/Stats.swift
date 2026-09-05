import Darwin
import Foundation

/// What untofu has actually done, counted rather than inferred.
///
/// The point is discoverability. This tool's whole design is to be invisible —
/// no Dock icon, no menu bar, no window unless something needs saying — and the
/// cost of that is a user who has no idea whether it has ever done anything. On
/// the machine this was written on it had served 1314 font requests from fonts
/// already on the disk and fetched 50 more, and none of that was visible
/// anywhere.
///
/// Counted, not parsed. The log holds the same history, but reading numbers back
/// out of log prose means a reworded line silently becomes a wrong total, and
/// this codebase has already shipped one test that passed because it grepped for
/// a word rather than an outcome. It is also unbounded and unrotated, so it is
/// not a thing to build a feature on.
final class Stats {

    struct Counters: Codable {
        /// Downloaded from Google Fonts and verified.
        var fetched = 0
        /// Served from a font already on this Mac that nothing had registered.
        var servedLocal = 0
        /// Served from the fetch cache.
        var servedCache = 0
        /// Asked for, and genuinely not obtainable.
        var unresolved = 0
        /// When counting began — nil until the first write.
        var since: Date?
        /// Whether the starting numbers were recovered from the log rather than
        /// counted. Recorded so a total can say how it knows.
        var seededFromLog = false

        var totalServed: Int { servedLocal + servedCache }
    }

    static let url = Cache.root.appendingPathComponent("stats.json")

    /// At most one write per this many seconds, however busy things get. A
    /// document with forty missing fonts must not become forty file writes.
    static let flushInterval: TimeInterval = 30

    private let lock = NSLock()
    private var pending = Counters()          // deltas not yet on disk
    private var lastFlush = Date.distantPast

    // MARK: - Counting

    /// Cheap enough for the provider callback: one lock, one integer, no I/O.
    /// The callback already writes a log line, which costs strictly more.
    func record(servedLocal: Int = 0, servedCache: Int = 0,
                fetched: Int = 0, unresolved: Int = 0) {
        lock.lock()
        pending.servedLocal += servedLocal
        pending.servedCache += servedCache
        pending.fetched += fetched
        pending.unresolved += unresolved
        let due = Date().timeIntervalSince(lastFlush) > Stats.flushInterval
        lock.unlock()
        if due { flush() }
    }

    /// Adds the pending deltas to what is on disk.
    ///
    /// Deltas, not absolutes, and under the same cross-process lock the cache
    /// uses — several processes count at once (the agent serving, a `untofu
    /// fetch` in a shell) and last-writer-wins would throw away whichever of
    /// them was slower.
    func flush() {
        lock.lock()
        let delta = pending
        guard delta.fetched != 0 || delta.servedLocal != 0
           || delta.servedCache != 0 || delta.unresolved != 0 else {
            lock.unlock(); return
        }
        pending = Counters()
        lastFlush = Date()
        lock.unlock()

        Stats.withFileLock {
            var stored = Stats.readUnlocked() ?? Counters()
            stored.fetched += delta.fetched
            stored.servedLocal += delta.servedLocal
            stored.servedCache += delta.servedCache
            stored.unresolved += delta.unresolved
            if stored.since == nil { stored.since = Date() }
            Stats.writeUnlocked(stored)
        }
    }

    // MARK: - Reading

    static func read() -> Counters? {
        var result: Counters?
        withFileLock { result = readUnlocked() }
        return result
    }

    private static func readUnlocked() -> Counters? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Counters.self, from: data)
    }

    private static func writeUnlocked(_ counters: Counters) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(counters) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Seeding

    /// Recovers a starting total from the log, once, for installs that predate
    /// counting.
    ///
    /// Otherwise everyone who has been running this for weeks is told it has
    /// done nothing, which is both wrong and the opposite of the point. Runs
    /// only when there is no stats file at all, and marks what it produced as
    /// recovered — the log is prose and a best-effort read of it should not
    /// masquerade as having been counted.
    ///
    /// Blocking. Background queue only.
    @discardableResult
    static func seedFromLogIfNeeded(logs: [URL]) -> Counters? {
        guard read() == nil else { return nil }
        // Whichever exists and has the most in it: a machine may carry both a
        // standalone log and a Homebrew one, and the longer is the real history.
        let text = logs
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .max(by: { $0.count < $1.count })
        guard let text else { return nil }

        var seeded = Counters()
        var earliest: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Timestamps lead every line: "2026-08-15 09:57:15 ...".
            if earliest == nil, line.count > 19 { earliest = String(line.prefix(19)) }
            // Matched on the shape the logger emits, anchored past the
            // timestamp so a font NAMED "hit" cannot inflate anything.
            let body = line.count > 20 ? line.dropFirst(20) : line

            // Each of these has a near neighbour that means something else
            // entirely, and every one of them was counted as a serve on the
            // first attempt. "local index: 581 unregistered face(s)" is a
            // startup report, not 581 documents helped — it inflated the total
            // by 66 on this machine's log alone. Anchoring on the prefix is not
            // enough when the prose starts the same way.
            if body.hasPrefix("local ") && !body.hasPrefix("local index") {
                seeded.servedLocal += 1
            } else if body.hasPrefix("hit ") {
                seeded.servedCache += 1
            } else if body.hasPrefix("fetched ") {
                seeded.fetched += 1
            } else if body.hasPrefix("unresolved ") && !body.hasPrefix("unresolved panel") {
                seeded.unresolved += 1
            }
        }
        guard seeded.totalServed + seeded.fetched > 0 else { return nil }

        seeded.seededFromLog = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        seeded.since = earliest.flatMap(formatter.date(from:))

        withFileLock { writeUnlocked(seeded) }
        Log.info("recovered a starting total from the log: \(seeded.fetched) fetched, "
               + "\(seeded.totalServed) served")
        return seeded
    }

    // MARK: - Cross-process lock

    private static var lockURL: URL { Cache.root.appendingPathComponent("stats.lock") }

    private static func withFileLock(_ body: () -> Void) {
        try? FileManager.default.createDirectory(
            at: Cache.root, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { body(); return }   // no lock is better than no write
        flock(fd, LOCK_EX)
        body()
        flock(fd, LOCK_UN)
        close(fd)
    }

    // MARK: - Presentation

    /// One quiet line for a window that is being drawn anyway.
    ///
    /// Deliberately not its own window, its own notification, or a badge. The
    /// tool interrupts for exactly two reasons — a font arrived, or one could
    /// not be found — and this rides along with those rather than inventing a
    /// third.
    static func summaryLine() -> String? {
        guard let c = read(), c.fetched + c.totalServed > 0 else { return nil }
        var parts: [String] = []
        if c.fetched > 0 {
            parts.append("fetched \(c.fetched) font\(c.fetched == 1 ? "" : "s")")
        }
        if c.totalServed > 0 {
            parts.append("answered \(c.totalServed.formatted()) request\(c.totalServed == 1 ? "" : "s")")
        }
        guard !parts.isEmpty else { return nil }

        var line = "untofu has " + parts.joined(separator: " and ")
        if let since = c.since {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMMM yyyy"
            line += " since \(formatter.string(from: since))"
        }
        return line + "."
    }
}
