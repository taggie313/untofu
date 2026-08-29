import Foundation

/// Fonts that are already on this Mac but that no application can see.
///
/// A font being "missing" almost never means the bytes are absent. Microsoft
/// ships 251 faces inside the Office application bundles and registers them
/// privately, so Word can set Calibri and Keynote cannot. Adobe syncs activated
/// Adobe Fonts into CoreSync as hidden, numerically-named files that only Adobe
/// applications resolve. Office writes fonts it downloads on demand into a cloud
/// cache under its group container. In every case the file is sitting on the
/// disk, readable, and invisible to the document that wants it.
///
/// This is the cheapest possible answer to a font request and the only one that
/// needs no network: walk those places once at startup, read the real PostScript
/// names out of each file, and serve the path straight back to CoreText. The
/// system issues the requesting process a sandbox extension for whatever URL the
/// hook returns, which is what lets Keynote read a font out of Excel's bundle.
///
/// Because the index is built before the first request arrives, a local hit is
/// answered synchronously and the document renders correctly the first time —
/// unlike a fetch, which is necessarily too late for the layout that triggered it.
final class LocalFonts {

    /// A place worth looking, and how to describe it to a human.
    struct Stash {
        let label: String
        let url: URL
        /// How far below `url` to descend. Kept tight: these are known layouts,
        /// not a search of the whole disk.
        let depth: Int
        /// Adobe hides its synced fonts in `.w/` and `.r/`, so hidden entries
        /// cannot be skipped globally — only where they are known to be noise.
        let includeHidden: Bool
    }

    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]

    /// Files that are shaped like fonts but are not usable as one.
    ///
    /// Office builds a single atlas containing sample text for its font picker,
    /// and iWork ships a face whose glyphs are all blank for rendering invisible
    /// characters. Both parse perfectly well and would be indexed under whatever
    /// name their `name` table claims.
    private static let excludedNames: Set<String> = [
        "invisible_glyphs.ttf", "lastresort.otf",
    ]
    private static let excludedFragments = ["officefontspreview", "fontpreview"]

    static func stashes() -> [Stash] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [Stash] = []

        // Office bundles each carry the full set, so this is the same 251 faces
        // two or three times over. Enumerating them all is cheaper than deciding
        // which bundle is canonical, and the scoring in refresh() collapses the
        // duplicates to one file per name anyway.
        let apps = (try? FileManager.default.contentsOfDirectory(
            atPath: "/Applications")) ?? []
        for app in apps.sorted() where app.hasPrefix("Microsoft ") && app.hasSuffix(".app") {
            found.append(Stash(label: "Microsoft Office",
                               url: URL(fileURLWithPath: "/Applications/\(app)/Contents/Resources/DFonts"),
                               depth: 1, includeHidden: false))
        }

        // Where Office puts a font it downloaded rather than shipped. This is the
        // one that closes the loop on the failure that prompted all of this: open
        // the deck in PowerPoint once and "Aptos Display" lands here, after which
        // every other application on the Mac can have it too.
        found.append(Stash(label: "Office cloud fonts",
                           url: home.appendingPathComponent(
                               "Library/Group Containers/UBF8T346G9.Office/FontCache"),
                           depth: 4, includeHidden: false))

        // Adobe Fonts activated through Creative Cloud, stored as hidden files
        // with numeric names. The names on disk say nothing; the `name` table says
        // everything, which is why this works at all.
        for root in ["Library/Application Support/Adobe/CoreSync/plugins/livetype",
                     "Library/Application Support/Adobe/Fonts"] {
            found.append(Stash(label: "Adobe Creative Cloud",
                               url: home.appendingPathComponent(root),
                               depth: 3, includeHidden: true))
            found.append(Stash(label: "Adobe Creative Cloud",
                               url: URL(fileURLWithPath: "/\(root)"),
                               depth: 3, includeHidden: true))
        }

        found.append(Stash(label: "Apple bundled fonts",
                           url: URL(fileURLWithPath: "/Library/Application Support/Apple/Fonts"),
                           depth: 2, includeHidden: false))

        // The "I downloaded the font and never double-clicked it" case, which is
        // common enough to be worth one shallow pass. Deliberately shallow: this
        // is a directory full of unrelated things, not a font library.
        found.append(Stash(label: "Downloads",
                           url: home.appendingPathComponent("Downloads"),
                           depth: 2, includeHidden: false))

        return found.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    // MARK: - Index

    private let lock = NSLock()
    private var index: [String: String] = [:]       // lowercased PostScript name -> absolute path
    private var origins: [String: String] = [:]     // absolute path -> stash label
    private var lastScan: (files: Int, faces: Int, duration: TimeInterval)?

    /// Hot path: a dictionary read under a lock, no I/O, same contract as `Cache.path`.
    func path(for psName: String) -> String? {
        let key = psName.lowercased()
        lock.lock(); defer { lock.unlock() }
        return index[key]
    }

    /// Which stash a served path came from, for logging and for the dialog.
    func origin(ofPath path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return origins[path]
    }

    var faceCount: Int { lock.lock(); defer { lock.unlock() }; return index.count }
    var summary: (files: Int, faces: Int, duration: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }; return lastScan
    }

    /// Every indexed name, for `untofu local`.
    var entries: [(psName: String, path: String, origin: String)] {
        lock.lock(); defer { lock.unlock() }
        return index.map { (psName: $0.key, path: $0.value, origin: origins[$0.value] ?? "?") }
            .sorted { $0.psName < $1.psName }
    }

    /// Walks the stashes and parses what it finds. Blocking — callers run it on a
    /// background queue, never from the provider callback.
    @discardableResult
    func refresh() -> Int {
        let started = Date()
        var freshIndex: [String: String] = [:]
        var freshOrigins: [String: String] = [:]
        var fileCount = 0

        // Best score wins rather than first writer, because several files
        // legitimately answer to the same name and picking wrong is visible:
        // every face in a family carries the family name, so a request for bare
        // "Calibri" is satisfiable by Calibrii.ttf and the document comes out in
        // italic. Ties fall back to stash order, so an Office bundle beats a
        // stray download.
        var scores: [String: Int] = [:]

        for (rank, stash) in LocalFonts.stashes().enumerated() {
            for file in LocalFonts.fontFiles(in: stash) {
                fileCount += 1
                guard let parsed = FontFile.read(file) else { continue }
                freshOrigins[file.path] = stash.label
                for name in parsed.postScriptNames {
                    let key = name.lowercased()
                    // A name that identifies this exact face beats one shared
                    // with every sibling, whatever their weights.
                    let score = (parsed.exactNames.contains(name) ? 10_000 : parsed.plainness)
                              - rank
                    if score > (scores[key] ?? Int.min) {
                        scores[key] = score
                        freshIndex[key] = file.path
                    }
                }
            }
        }

        // Drop origins for files that contributed no name, so `untofu local`
        // does not claim to have indexed something it discarded.
        freshOrigins = freshOrigins.filter { freshIndex.values.contains($0.key) }

        let elapsed = Date().timeIntervalSince(started)
        lock.lock()
        index = freshIndex
        origins = freshOrigins
        lastScan = (files: fileCount, faces: freshIndex.count, duration: elapsed)
        lock.unlock()

        // Debug, not info: `status`, `explain` and `local` all refresh, and each
        // printing a line about it buries their actual output. The agent logs
        // its own startup scan at info, where it is the useful thing to know.
        Log.debug("local index: \(freshIndex.count) face(s) from \(fileCount) file(s) "
                + "in \(String(format: "%.2f", elapsed))s")
        return freshIndex.count
    }

    private static func fontFiles(in stash: Stash) -> [URL] {
        var out: [URL] = []
        var frontier = [(url: stash.url, depth: 0)]

        while let current = frontier.popLast() {
            let options: FileManager.DirectoryEnumerationOptions =
                stash.includeHidden ? [] : [.skipsHiddenFiles]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: current.url, includingPropertiesForKeys: [.isDirectoryKey],
                options: options)) ?? []

            for entry in contents {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if isDirectory {
                    if current.depth + 1 < stash.depth {
                        frontier.append((url: entry, depth: current.depth + 1))
                    }
                    continue
                }
                guard fontExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                let name = entry.lastPathComponent.lowercased()
                guard !excludedNames.contains(name),
                      !excludedFragments.contains(where: { name.contains($0) })
                else { continue }
                out.append(entry)
            }
        }
        return out
    }
}
