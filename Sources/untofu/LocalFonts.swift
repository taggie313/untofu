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
        /// Whether reading here makes macOS interrupt the user for permission.
        ///
        /// Downloads, and anything under another application's container, are
        /// gated by TCC. A background font agent reaching into them uninvited
        /// produces exactly the dialog this whole tool exists to remove — one
        /// the user did not ask for and cannot make sense of, from a process
        /// with no window and no obvious reason to want their Downloads folder.
        /// So these are off unless the user turns them on, deliberately, in the
        /// foreground, where the prompt is an answer to something they just did.
        let needsPermission: Bool
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

    /// Everywhere worth looking.
    ///
    /// `includingPersonal` decides whether the TCC-gated ones come along. The
    /// default is no, and that is a deliberate trade: the Office cloud cache is
    /// where "Aptos Display" lands once PowerPoint fetches it, and Adobe's
    /// CoreSync directory is the only place activated Adobe Fonts exist — both
    /// genuinely useful, and neither worth a permission dialog the user did not
    /// ask for from a process they cannot see.
    static func stashes(includingPersonal personal: Bool = false) -> [Stash] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [Stash] = []

        // Office bundles each carry the full set, so this is the same 251 faces
        // two or three times over. Enumerating them all is cheaper than deciding
        // which bundle is canonical, and the scoring in refresh() collapses the
        // duplicates to one file per name anyway.
        //
        // Inside /Applications, so no permission is involved: this is the bulk
        // of what the feature delivers and it costs the user nothing.
        let apps = (try? FileManager.default.contentsOfDirectory(
            atPath: "/Applications")) ?? []
        for app in apps.sorted() where app.hasPrefix("Microsoft ") && app.hasSuffix(".app") {
            found.append(Stash(label: "Microsoft Office",
                               url: URL(fileURLWithPath: "/Applications/\(app)/Contents/Resources/DFonts"),
                               depth: 1, includeHidden: false, needsPermission: false))
        }

        // Machine-wide rather than per-user, so not behind TCC.
        found.append(Stash(label: "Adobe (shared)",
                           url: URL(fileURLWithPath: "/Library/Application Support/Adobe/Fonts"),
                           depth: 3, includeHidden: true, needsPermission: false))
        found.append(Stash(label: "Apple bundled fonts",
                           url: URL(fileURLWithPath: "/Library/Application Support/Apple/Fonts"),
                           depth: 2, includeHidden: false, needsPermission: false))

        if personal {
            // Where Office puts a font it downloaded rather than shipped — the
            // one that closes the loop on the failure that started all of this.
            found.append(Stash(label: "Office cloud fonts",
                               url: home.appendingPathComponent(
                                   "Library/Group Containers/UBF8T346G9.Office/FontCache"),
                               depth: 4, includeHidden: false, needsPermission: true))

            // Adobe Fonts activated through Creative Cloud, stored as hidden
            // files with numeric names. The names on disk say nothing; the
            // `name` table says everything, which is why this works at all.
            found.append(Stash(label: "Adobe Creative Cloud",
                               url: home.appendingPathComponent(
                                   "Library/Application Support/Adobe/CoreSync/plugins/livetype"),
                               depth: 3, includeHidden: true, needsPermission: true))

            // The "I downloaded the font and never double-clicked it" case.
            // Deliberately shallow: a directory full of unrelated things, not a
            // font library.
            found.append(Stash(label: "Downloads",
                               url: home.appendingPathComponent("Downloads"),
                               depth: 2, includeHidden: false, needsPermission: true))
        }

        return found.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// The gated locations, whether or not they are currently enabled — so
    /// `untofu folders` can name what is being passed up.
    static var personalStashes: [Stash] {
        stashes(includingPersonal: true).filter(\.needsPermission)
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
        /// Which stash this came from, for `untofu local` and the dialog.
        let origin: String
        /// Whether reading it required a permission the agent does not ask for.
        /// These entries are carried forward on trust rather than re-walked.
        let gated: Bool
        /// Stash priority, so a tie between two files resolves the same way it
        /// would have during a walk even when one side came from the snapshot.
        let rank: Int
    }

    private struct Snapshot: Codable {
        /// Bumped when the shape of Entry changes, so an old file on disk is
        /// discarded wholesale rather than decoded into something wrong.
        let version: Int
        let files: [String: Entry]
    }

    /// Bumped whenever the SHAPE of Entry changes — and also whenever the
    /// PARSER changes, which is less obvious and was nearly missed.
    ///
    /// The snapshot is keyed by path, size and modification date, so a font file
    /// that has not changed is never re-read. That is the whole point of it, and
    /// it means a fix to how fonts are *parsed* reaches nobody: every existing
    /// install would go on serving name sets produced by the old code. Version 4
    /// is the CJK name-record fix — without this line it would have shipped and
    /// silently done nothing for anyone who had ever run the tool before.
    private static let snapshotVersion = 4

    /// What to do about the font stashes macOS gates behind a permission prompt.
    ///
    /// The agent must never walk them. Not because it lacks permission — it can
    /// be granted — but because the grant does not stick: it re-prompted on a
    /// later restart of the very same installed binary, and a background agent
    /// that interrupts you at login is worse than one that misses a few fonts.
    ///
    /// So the walk and the serve are separated. The CLI walks, in the
    /// foreground, when you ask it to; the agent serves what the CLI recorded,
    /// having never opened those directories. Which works because a provider
    /// does not need access to the file it names — the client reads it, through
    /// the sandbox extension CoreText issues for the returned URL. Measured
    /// rather than assumed: Calibri's own glyph data, served from a gated
    /// directory by a provider with no access to it, rendered in Keynote
    /// identically to the installed font.
    enum GatedPolicy {
        /// Not opted in. Gated entries are ignored and dropped from the snapshot.
        case exclude
        /// Opted in, and this process must not prompt. Serve what the snapshot
        /// already records, and never touch those directories. The agent.
        case trustSnapshot
        /// Opted in, user-invoked, in the foreground. Walk them and record what
        /// is there — this is the one place a permission prompt is acceptable,
        /// because it answers something the user just did.
        case walk
    }

    struct Scan {
        let files: Int
        let faces: Int
        let duration: TimeInterval
        /// Files whose contents had to be read this time.
        let parsed: Int
        /// Bytes read to do it. This is the number that matters: it is what the
        /// cold start was actually spending its time on.
        let bytesRead: Int64
        /// Entries carried forward from the snapshot without being looked at,
        /// because looking would have prompted.
        let trusted: Int
    }

    private let lock = NSLock()

    /// Serializes the walk in `refresh`.
    ///
    /// Deliberately NOT `lock`. That one is taken on the CoreText callback path
    /// by `path(for:)`, so a walk holding it would block every application's
    /// text layout for as long as the walk takes — 34 seconds on a cold run —
    /// and would deadlock against its own publish at the end.
    ///
    /// Without this, two walks overlap: the startup walk begins, a SIGHUP or a
    /// `folders --rescan` starts a second one, and each loads the record at the
    /// beginning and writes its own map at the end. The later write wins whole,
    /// so whatever the earlier one learned is lost and has to be re-read next
    /// time. The window is the length of a walk, which on a first run is the
    /// better part of a minute.
    private let walkLock = NSLock()
    /// Size and modification date of the record as this process last read or
    /// wrote it. A watch event whose fingerprint matches this is our own write
    /// coming back at us, and acting on it would be a loop.
    private var lastFingerprint: String?
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

    /// Whether the record holds anything from a gated stash.
    ///
    /// False while opted in means the record was lost — the cache directory
    /// removed, or a first run after opting in — and those fonts are silently
    /// not being served despite the setting saying they are.
    static var recordHasGatedEntries: Bool {
        loadSnapshot().values.contains { $0.gated }
    }
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
        let words = Resolver.familyWords(for: psName)
        guard let first = words.first, !first.isEmpty,
              !LocalFonts.vendorPrefixes.contains(first) || words.count == 1
        else { return nil }

        lock.lock(); defer { lock.unlock() }
        // Sorted, so the answer does not change between runs for no reason.
        for name in index.keys.sorted() {
            guard name.lowercased() != psName.lowercased() else { continue }
            if Resolver.familyWords(for: name).first == first { return name }
        }
        return nil
    }

    /// First words that identify a vendor rather than a family.
    ///
    /// Matching on one of these is worse than not matching at all. A real report
    /// came back saying "MS Outlook" was found locally because "MS Reference
    /// Sans Serif" is on the disk — they share nothing but the vendor prefix, so
    /// the dialog offered the user a meaningless consolation and the miss report
    /// carried `found_locally: true` about a font that is nowhere on the machine.
    private static let vendorPrefixes: Set<String> = ["ms", "microsoft", "adobe", "apple", "google"]

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
    func refresh(rebuild: Bool = false, gated: GatedPolicy = .exclude) -> Int {
        walkLock.lock(); defer { walkLock.unlock() }
        let started = Date()
        let previous = rebuild ? [:] : LocalFonts.loadSnapshot()

        var current: [String: Entry] = [:]
        var fileCount = 0
        var parsedCount = 0
        var trustedCount = 0
        var bytesRead: Int64 = 0

        // Walk what this process is allowed to walk. Under .trustSnapshot the
        // gated stashes are not even enumerated — enumerating is the thing that
        // prompts.
        let walking = LocalFonts.stashes(includingPersonal: gated == .walk)
        for (rank, stash) in walking.enumerated() {
            for file in LocalFonts.fontFiles(in: stash) {
                fileCount += 1
                let entry: Entry
                if let cached = previous[file.url.path],
                   cached.size == file.size, cached.modified == file.modified {
                    entry = Entry(size: cached.size, modified: cached.modified,
                                  names: cached.names, exact: cached.exact,
                                  plainness: cached.plainness, origin: stash.label,
                                  gated: stash.needsPermission, rank: rank)
                } else {
                    guard let parsed = FontFile.read(file.url) else { continue }
                    entry = Entry(size: file.size, modified: file.modified,
                                  names: Array(parsed.postScriptNames),
                                  exact: Array(parsed.exactNames),
                                  plainness: parsed.plainness, origin: stash.label,
                                  gated: stash.needsPermission, rank: rank)
                    parsedCount += 1
                    bytesRead += file.size
                }
                current[file.url.path] = entry
            }
        }

        // Carry forward what the CLI recorded and this process must not look at.
        // Taken entirely on trust: a file deleted since the last walk leaves a
        // path CoreText simply rejects, which degrades to the behaviour before
        // any of this existed. `untofu folders --rescan` refreshes them.
        if gated == .trustSnapshot {
            for (path, entry) in previous where entry.gated && current[path] == nil {
                current[path] = entry
                trustedCount += 1
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        let faces = publish(current, scan: { faces in
            Scan(files: fileCount, faces: faces, duration: elapsed,
                 parsed: parsedCount, bytesRead: bytesRead, trusted: trustedCount)
        })
        _ = faces

        // Never write over a record a newer build owns; see snapshotIsFromNewerBuild.
        if LocalFonts.snapshotIsFromNewerBuild() {
            Log.debug("not saving: local-index.json belongs to a newer build")
        } else {
            LocalFonts.saveSnapshot(current)
        }
        rememberSnapshotFingerprint()

        Log.debug("local index: \(faceCount) face(s) from \(fileCount) walked "
                + "+ \(trustedCount) trusted, in \(String(format: "%.2f", elapsed))s "
                + "(\(parsedCount) read)")
        return faceCount
    }

    /// Scores a set of entries into the served index. Shared by the walk and by
    /// adopting the record, so both resolve identically — a second copy of this
    /// is a second chance for them to disagree about which face wins a name.
    @discardableResult
    private func publish(_ current: [String: Entry], scan: (Int) -> Scan) -> Int {
        // Best score wins rather than first writer, because several files
        // legitimately answer to the same name and picking wrong is visible:
        // every face in a family carries the family name, so a request for bare
        // "Calibri" is satisfiable by Calibrii.ttf and the document comes out in
        // italic. Ties fall back to stash order.
        var freshIndex: [String: String] = [:]
        var freshOrigins: [String: String] = [:]
        var scores: [String: Int] = [:]
        for (path, entry) in current.sorted(by: { $0.key < $1.key }) {
            freshOrigins[path] = entry.origin
            let exact = Set(entry.exact)
            for name in entry.names {
                let key = name.lowercased()
                // A name identifying this exact face beats one shared with every
                // sibling, whatever their weights.
                let score = (exact.contains(name) ? 10_000 : entry.plainness) - entry.rank
                if score > (scores[key] ?? Int.min) {
                    scores[key] = score
                    freshIndex[key] = path
                }
            }
        }
        let served = Set(freshIndex.values)
        freshOrigins = freshOrigins.filter { served.contains($0.key) }

        lock.lock()
        index = freshIndex
        origins = freshOrigins
        lastScan = scan(freshIndex.count)
        lock.unlock()
        return freshIndex.count
    }

    /// Rebuilds the served index from the record alone — no directories opened,
    /// nothing written.
    ///
    /// This is what the agent does when another process changes the record: the
    /// CLI has already walked and written the truth, so re-walking would only
    /// risk reaching somewhere this process must not touch, and re-writing would
    /// make the agent's own change wake it again.
    ///
    /// Returns false when the record has not actually changed since we last read
    /// or wrote it, which is the common case and the one that stops a feedback
    /// loop before it starts.
    @discardableResult
    func adoptSnapshot(gated: GatedPolicy) -> Bool {
        lock.lock()
        let known = lastFingerprint
        lock.unlock()
        guard LocalFonts.snapshotFingerprint() != known else { return false }

        let stored = LocalFonts.loadSnapshot()
        guard !stored.isEmpty else {
            // The file changed but nothing usable came back — it was written by a
            // build whose format this one does not share, in either direction.
            // Returning false here left the agent serving whatever it had in
            // memory, indefinitely and silently, which is the exact failure the
            // watch exists to prevent. Rebuild from the directories instead;
            // refresh() saves and re-fingerprints, so this settles rather than
            // looping.
            Log.info("the record is not in this build's format — rebuilding from disk")
            refresh(gated: gated)
            return true
        }
        let usable = gated == .exclude ? stored.filter { !$0.value.gated } : stored
        let trusted = usable.values.filter(\.gated).count

        publish(usable, scan: { faces in
            Scan(files: usable.count - trusted, faces: faces, duration: 0,
                 parsed: 0, bytesRead: 0, trusted: trusted)
        })
        rememberSnapshotFingerprint()
        Log.info("adopted the record: \(faceCount) local face(s)"
               + (trusted > 0 ? ", \(trusted) from folders this process never opens" : ""))
        return true
    }

    // MARK: - Snapshot

    static var snapshotURL: URL {
        Cache.root.appendingPathComponent("local-index.json")
    }

    /// Cheap identity for the record on disk. Deliberately not a content hash:
    /// this runs on every filesystem event and the file is ~150 KB.
    private static func snapshotFingerprint() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return "\(size)@\(modified.timeIntervalSince1970)"
    }

    private func rememberSnapshotFingerprint() {
        let current = LocalFonts.snapshotFingerprint()
        lock.lock(); lastFingerprint = current; lock.unlock()
    }

    /// True when the file on disk was written by a NEWER build than this one.
    ///
    /// An old binary must not overwrite a new binary's record. During an upgrade
    /// both exist at once — `brew upgrade` leaves the previous agent running, by
    /// design — and without this the old agent reads a format it does not
    /// understand, discards it, and rewrites its own, purging the gated entries
    /// that only a foreground rescan can rebuild. It then does it again every
    /// time the new CLI writes. Observed exactly that while bumping to v4.
    ///
    /// This build cannot fix the one already installed, but it stops the same
    /// thing happening on every future bump.
    private static func snapshotIsFromNewerBuild() -> Bool {
        guard let data = try? Data(contentsOf: snapshotURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return false }
        return decoded.version > snapshotVersion
    }

    private static func loadSnapshot() -> [String: Entry] {
        guard let data = try? Data(contentsOf: snapshotURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return [:] }
        guard decoded.version != snapshotVersion else { return decoded.files }

        if decoded.version > snapshotVersion {
            Log.warn("local-index.json was written by a newer untofu (v\(decoded.version) "
                   + "> v\(snapshotVersion)); leaving it alone. Restart the agent so both "
                   + "sides are the same build.")
            return [:]
        }

        // An older snapshot. Everything in it was parsed by older code, so it all
        // has to be read again — except that the gated entries CANNOT be read
        // again. Only a deliberate, foreground `untofu folders --rescan` may open
        // those directories, so discarding them would quietly cost an opted-in
        // user their Adobe and Office cloud fonts on upgrade, with nothing but a
        // line in `status` to explain where they went.
        //
        // So keep the gated entries and drop the rest. Their names are whatever
        // the old parser produced — stale, but serving a font under an old
        // spelling beats not serving it — and `--rescan` refreshes them properly.
        let carried = decoded.files.filter { $0.value.gated }
        if carried.isEmpty {
            Log.debug("snapshot v\(decoded.version) discarded; re-reading everything")
        } else {
            Log.info("snapshot v\(decoded.version) is stale: re-reading what can be read, "
                   + "carrying \(carried.count) entr\(carried.count == 1 ? "y" : "ies") from "
                   + "permission-gated folders (`untofu folders --rescan` refreshes those)")
        }
        return carried
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
