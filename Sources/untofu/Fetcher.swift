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
        var unresolved: ((String) -> Void)?
    }

    @discardableResult
    static func fetch(psName: String, into cache: Cache,
                      observer: Observer? = nil) -> Bool {
        let candidates = Resolver.familyCandidates(for: psName)
        guard !candidates.isEmpty else { return false }

        // Skip families we know we can never supply. Nothing is fetched and,
        // crucially, the user is not told — a dialog listing Calibri and Segoe UI
        // every time a .pptx opens is noise they can do nothing about.
        if Resolver.isKnownProprietary(psName) {
            Log.debug("skipping \(psName): proprietary family, never on Google Fonts")
            cache.markUnresolved(psName)
            return false
        }
        Log.debug("resolving \(psName) via candidates: \(candidates.joined(separator: ", "))")

        // Per-fetch scratch directory. A shared one is a race: fetches run
        // concurrently, and the first to finish would delete the staging area out
        // from under the others on its way out.
        let scratch = cache.fontsDir
            .appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for slug in candidates {
            for license in GoogleFonts.licenseDirs {
                guard let files = GoogleFonts.listing(license: license, slug: slug) else { continue }
                Log.debug("\(license)/\(slug): \(files.count) font file(s)")

                for file in files.prefix(maxDownloadsPerAttempt) {
                    guard let local = GoogleFonts.download(file, to: scratch) else { continue }
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
                    guard let installed = adopt(local, into: cache) else { continue }
                    cache.record(installed)
                    Log.info("fetched \(psName) <- \(license)/\(slug)/\(file.name) "
                           + "(\(installed.postScriptNames.count) face(s) indexed)")
                    observer?.resolved?(Resolver.displayFamily(for: psName))
                    return true
                }
            }
        }

        Log.info("unresolved \(psName) — no Google Fonts family answers to it")
        cache.markUnresolved(psName)
        observer?.unresolved?(psName)
        return false
    }

    /// Moves a verified file out of scratch and into the cache proper.
    private static func adopt(_ file: URL, into cache: Cache) -> FontFile? {
        let destination = cache.fontsDir.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            Log.warn("could not install \(file.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        return FontFile.read(destination)
    }
}
