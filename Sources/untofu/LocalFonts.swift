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

    /// What was read out of one font file, kept so it need not be read twice.
    ///
    /// Keyed by path and validated against size and modification date. A font
    /// file is immutable in practice — Office ships them inside a signed bundle
    /// and Adobe writes a new numbered file rather than editing one — so this
    /// invalidates almost never, and when it does, only that file is re-read.
    private struct Entry: Codable {
        let size: Int64
        let modified: Double
        let names: [String]
        let exact: [String]
        let plainness: Int
    }

    private struct Snapshot: Codable {
        /// Bumped when the shape of Entry changes, so an old file on disk is
        /// discarded wholesale rather than decoded into something wrong.
        let version: Int
        let files: [String: Entry]
    }

    private static let snapshotVersion = 2

    struct Scan {
        let files: Int
        let faces: Int
        let duration: TimeInterval
        /// Files whose contents had to be read this time.
        let parsed: Int
        /// Bytes read to do it. This is the number that matters: it is what the
        /// cold start was actually spending its time on.
        let bytesRead: Int64
    }

    private let lock = NSLock()
    private var index: [String: String] = [:]       // lowercased PostScript name -> absolute path
    private var origins: [String: String] = [:]     // absolute path -> stash label
    private var lastScan: Scan?

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
    var summary: Scan? {
        lock.lock(); defer { lock.unlock() }; return lastScan
    }

    /// Every indexed name, for `untofu local`.
    var entries: [(psName: String, path: String, origin: String)] {
        lock.lock(); defer { lock.unlock() }
        return index.map { (psName: $0.key, path: $0.value, origin: origins[$0.value] ?? "?") }
            .sorted { $0.psName < $1.psName }
    }

    /// The name of a face from the same family, when the exact name asked for
    /// was not found but a relative was.
    ///
    /// This is what makes a miss report worth reading. By the time the panel
    /// appears the exact name has already failed every lookup, so asking "is
    /// this exact name on disk" would answer no every time and say nothing. The
    /// useful question is the other one: did we have the family all along and
    /// fail to connect the request to it? "Aptos Display is missing, but Aptos
    /// is sitting in Excel's bundle" is a resolver bug, and an entirely
    /// different thing from a font nobody publishes.
    func relative(of psName: String) -> String? {
        guard let first = Resolver.familyWords(for: psName).first, !first.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        // Sorted, so the answer does not change between runs for no reason.
        for name in index.keys.sorted() {
            guard name.lowercased() != psName.lowercased() else { continue }
            if Resolver.familyWords(for: name).first == first { return name }
        }
        return nil
    }

    /// Walks the stashes and reads what it has not read before. Blocking —
    /// callers run it on a background queue, never from the provider callback.
    ///
    /// Reading every file every time was the original shape, decided on a warm
    /// benchmark of 0.13s. That was the wrong measurement: these stashes are
    /// 1.35 GB across ~690 files, and the first run after a boot — the only one
    /// that matters, since it is the one racing the user's first document —
    /// measured 34 seconds. The parse results are cached against size and
    /// modification date, so that cost is paid once per file ever rather than
    /// once per login.
    @discardableResult
    func refresh(rebuild: Bool = false) -> Int {
        let started = Date()
        let previous = rebuild ? [:] : LocalFonts.loadSnapshot()

        var current: [String: Entry] = [:]
        var freshIndex: [String: String] = [:]
        var freshOrigins: [String: String] = [:]
        var scores: [String: Int] = [:]
        var fileCount = 0
        var parsedCount = 0
        var bytesRead: Int64 = 0

        // Best score wins rather than first writer, because several files
        // legitimately answer to the same name and picking wrong is visible:
        // every face in a family carries the family name, so a request for bare
        // "Calibri" is satisfiable by Calibrii.ttf and the document comes out in
        // italic. Ties fall back to stash order, so an Office bundle beats a
        // stray download.
        for (rank, stash) in LocalFonts.stashes().enumerated() {
            for file in LocalFonts.fontFiles(in: stash) {
                fileCount += 1

                let entry: Entry
                if let cached = previous[file.url.path],
                   cached.size == file.size, cached.modified == file.modified {
                    entry = cached
                } else {
                    guard let parsed = FontFile.read(file.url) else { continue }
                    entry = Entry(size: file.size, modified: file.modified,
                                  names: Array(parsed.postScriptNames),
                                  exact: Array(parsed.exactNames),
                                  plainness: parsed.plainness)
                    parsedCount += 1
                    bytesRead += file.size
                }

                current[file.url.path] = entry
                freshOrigins[file.url.path] = stash.label

                let exact = Set(entry.exact)
                for name in entry.names {
                    let key = name.lowercased()
                    // A name that identifies this exact face beats one shared
                    // with every sibling, whatever their weights.
                    let score = (exact.contains(name) ? 10_000 : entry.plainness) - rank
                    if score > (scores[key] ?? Int.min) {
                        scores[key] = score
                        freshIndex[key] = file.url.path
                    }
                }
            }
        }

        // Drop origins for files that contributed no name, so `untofu local`
        // does not claim to have indexed something it discarded.
        let served = Set(freshIndex.values)
        freshOrigins = freshOrigins.filter { served.contains($0.key) }

        let elapsed = Date().timeIntervalSince(started)
        lock.lock()
        index = freshIndex
        origins = freshOrigins
        lastScan = Scan(files: fileCount, faces: freshIndex.count, duration: elapsed,
                        parsed: parsedCount, bytesRead: bytesRead)
        lock.unlock()

        // Written even when nothing was parsed: files disappear too, and a
        // snapshot still naming them would keep them alive forever.
        LocalFonts.saveSnapshot(current)

        Log.debug("local index: \(freshIndex.count) face(s) from \(fileCount) file(s) "
                + "in \(String(format: "%.2f", elapsed))s "
                + "(\(parsedCount) read, \(fileCount - parsedCount) reused)")
        return freshIndex.count
    }

    // MARK: - Snapshot

    static var snapshotURL: URL {
        Cache.root.appendingPathComponent("local-index.json")
    }

    private static func loadSnapshot() -> [String: Entry] {
        guard let data = try? Data(contentsOf: snapshotURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data),
              decoded.version == snapshotVersion
        else { return [:] }
        return decoded.files
    }

    private static func saveSnapshot(_ files: [String: Entry]) {
        let encoder = JSONEncoder()
        // Not pretty-printed: this is ~690 entries of machine-read bookkeeping,
        // and the readable view of it is `untofu local`.
        guard let data = try? encoder.encode(Snapshot(version: snapshotVersion, files: files))
        else { return }
        try? FileManager.default.createDirectory(
            at: Cache.root, withIntermediateDirectories: true)
        // Atomic: several processes refresh — the agent, and any CLI command
        // that reports on the index — and a half-written file read by the next
        // one would send it back to re-reading all 1.35 GB.
        try? data.write(to: snapshotURL, options: .atomic)
    }

    /// A font file, with the two facts needed to tell whether it has changed.
    ///
    /// Size and date come from the directory enumeration rather than a separate
    /// stat per file: they are prefetched as resource values, so validating ~690
    /// cached entries costs one walk and no extra syscalls.
    private struct Found {
        let url: URL
        let size: Int64
        let modified: Double
    }

    private static func fontFiles(in stash: Stash) -> [Found] {
        var out: [Found] = []
        var frontier = [(url: stash.url, depth: 0)]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        while let current = frontier.popLast() {
            let options: FileManager.DirectoryEnumerationOptions =
                stash.includeHidden ? [] : [.skipsHiddenFiles]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: current.url, includingPropertiesForKeys: keys,
                options: options)) ?? []

            for entry in contents {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
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
                out.append(Found(
                    url: entry,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return out
    }
}
