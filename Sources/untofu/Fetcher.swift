import Darwin
import Foundation

/// Resolve a PostScript name to a font file, verify it, and cache it.
///
/// Blocking and slow by nature. Runs only on the background queue.
enum Fetcher {
    /// Upper bound on downloads per attempt. Some families ship 30+ static
    /// instances; with variable fonts sorted first, a match almost always lands
    /// in the first file or two.
    static let maxDownloadsPerAttempt = 8

    /// Reports the outcome of a fetch. The CLI leaves this nil — it already
    /// prints what happened, and a banner announcing something the user just
    /// typed is noise.
    struct Observer {
        /// Human-readable family name, e.g. "Playfair Display".
        var resolved: ((String) -> Void)?
        /// The raw PostScript name, which is what the user needs to search for.
        ///
        /// Fires only when the catalogue was actually consulted and does not
        /// have the font. A lookup that could not be made — rate limited, no
        /// network — is not an answer, and telling the user their font is
        /// "commercial or private" on the strength of it is a lie.
        var unresolved: ((String) -> Void)?
    }

    /// Why a fetch ended.
    enum Outcome {
        case fetched
        /// The catalogue was consulted and does not have it.
        case absent
        /// It could not be consulted. Carries why, for the log and the CLI.
        case unreachable(String)

        var succeeded: Bool { if case .fetched = self { return true }; return false }
    }

    @discardableResult
    static func fetch(psName: String, into cache: Cache,
                      observer: Observer? = nil) -> Bool {
        resolve(psName: psName, into: cache, observer: observer).succeeded
    }

    static func resolve(psName: String, into cache: Cache,
                        observer: Observer? = nil) -> Outcome {
        let candidates = Resolver.familyCandidates(for: psName)
        guard !candidates.isEmpty else { return .absent }

        // Skip families we know we can never supply. Nothing is fetched and,
        // crucially, the user is not told — a dialog listing Calibri and Segoe UI
        // every time a .pptx opens is noise they can do nothing about.
        if Resolver.isKnownProprietary(psName) {
            Log.debug("skipping \(psName): proprietary family, never on Google Fonts")
            cache.markUnresolved(psName)
            return .absent
        }
        Log.debug("resolving \(psName) via candidates: \(candidates.joined(separator: ", "))")

        // Per-fetch scratch directory. A shared one is a race: fetches run
        // concurrently, and the first to finish would delete the staging area out
        // from under the others on its way out.
        let scratch = cache.fontsDir
            .appendingPathComponent(Cache.scratchName(), isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Tracks whether any lookup failed to happen, as opposed to answering no.
        var blocked: String?

        for slug in candidates {
            for license in GoogleFonts.licenseDirs {
                let files: [GoogleFonts.RemoteFile]
                switch GoogleFonts.listing(license: license, slug: slug) {
                case .found(let f): files = f
                case .absent: continue
                case .unreachable(let why): blocked = why; continue
                }
                Log.debug("\(license)/\(slug): \(files.count) font file(s)")

                for file in files.prefix(maxDownloadsPerAttempt) {
                    let local: URL
                    switch GoogleFonts.download(file, to: scratch) {
                    case .saved(let url): local = url
                    case .unreachable(let why):
                        // Never evidence about the font: it did not arrive.
                        blocked = why
                        continue
                    }
                    guard let parsed = FontFile.read(local) else {
                        try? FileManager.default.removeItem(at: local)
                        continue
                    }
                    // The whole point of the verification: a family-name match is
                    // not enough, the file must actually answer to the exact name
                    // that was requested.
                    guard parsed.answers(to: psName) else {
                        Log.debug("\(file.name) does not answer to \(psName)")
                        try? FileManager.default.removeItem(at: local)
                        continue
                    }
                    // Reaching here means the file downloaded, parsed, and
                    // answers to the exact name asked for — the strongest
                    // evidence this tool can gather that the font exists. If
                    // installing it then fails (a full disk, a permissions
                    // problem), that is a fact about this machine and must not
                    // become "no such font": doing so would take the one case
                    // we are surest about and give it the harshest outcome.
                    guard let installed = adopt(local, into: cache) else {
                        blocked = "downloaded \(file.name) but could not install it"
                        continue
                    }
                    cache.record(installed)
                    Log.info("fetched \(psName) <- \(license)/\(slug)/\(file.name) "
                           + "(\(installed.postScriptNames.count) face(s) indexed)")
                    observer?.resolved?(Resolver.displayFamily(for: psName))
                    return .fetched
                }
            }
        }

        // The distinction the whole type exists for. Marking a name unresolved
        // suppresses it for six hours and tells the user it is commercial or
        // private; doing that because we could not reach GitHub is simply
        // false, and it used to happen on every rate limit and every dropped
        // connection.
        if let why = blocked {
            Log.info("could not resolve \(psName): \(why) — not caching that as a miss")
            return .unreachable(why)
        }

        Log.info("unresolved \(psName) — no Google Fonts family answers to it")
        cache.markUnresolved(psName)
        observer?.unresolved?(psName)
        return .absent
    }

    /// Moves a verified file out of scratch and into the cache proper.
    private static func adopt(_ file: URL, into cache: Cache) -> FontFile? {
        let destination = cache.fontsDir.appendingPathComponent(file.lastPathComponent)

        // rename(2), not removeItem-then-moveItem.
        //
        // Two fetches can legitimately land on the same file: `Raleway-Bold` and
        // `RalewayRoman-Regular` are different names with different in-flight
        // keys, both resolve to `ofl/raleway`, and both download
        // `Raleway[wght].ttf`. The unlink-then-move pair gives that pair two
        // ways to hurt each other — a window where the destination does not
        // exist at all, which the index may already be pointing at, and then a
        // move that fails outright because the other side recreated it.
        //
        // rename replaces atomically. The loser overwrites with identical bytes
        // and both callers succeed. Both paths are inside fontsDir, so this is
        // never a cross-device rename.
        guard rename(file.path, destination.path) == 0 else {
            Log.warn("could not install \(file.lastPathComponent): "
                   + String(cString: strerror(errno)))
            return nil
        }
        return FontFile.read(destination)
    }
}
