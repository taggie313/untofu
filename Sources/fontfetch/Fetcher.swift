import Foundation

/// Resolve a PostScript name to a font file, verify it, and cache it.
///
/// Blocking and slow by nature. Runs only on the background queue.
enum Fetcher {
    /// Upper bound on downloads per attempt. Some families ship 30+ static
    /// instances; with variable fonts sorted first, a match almost always lands
    /// in the first file or two.
    static let maxDownloadsPerAttempt = 8

    /// `notify` is called with a human-readable family name on success. The CLI
    /// leaves it nil — it already prints what happened, and a banner announcing
    /// something the user just typed is noise.
    @discardableResult
    static func fetch(psName: String, into cache: Cache,
                      notify: ((String) -> Void)? = nil) -> Bool {
        let candidates = Resolver.familyCandidates(for: psName)
        guard !candidates.isEmpty else { return false }
        Log.debug("resolving \(psName) via candidates: \(candidates.joined(separator: ", "))")

        let scratch = cache.fontsDir.appendingPathComponent(".incoming", isDirectory: true)
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
                    notify?(Resolver.displayFamily(for: psName))
                    return true
                }
            }
        }

        Log.info("unresolved \(psName) — no Google Fonts family answers to it")
        cache.markUnresolved(psName)
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
