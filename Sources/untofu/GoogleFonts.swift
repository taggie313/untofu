import Foundation

/// Minimal client for the google/fonts repository.
///
/// Everything here performs blocking network I/O and must never be called from
/// the provider callback — see Provider.handle for the split.
enum GoogleFonts {
    /// google/fonts partitions families by license directory.
    static let licenseDirs = ["ofl", "apache", "ufl"]

    /// Base of the GitHub API, overridable so the failure paths can be tested.
    ///
    /// Everything interesting about this client is how it behaves when GitHub
    /// says no: a rate limit, a transport error and a genuine 404 have to stay
    /// distinguishable all the way up to the dialog, and there is no way to
    /// exercise that against the real API without either waiting out a rate
    /// limit or unplugging the network. The selftest points this at a local
    /// server that returns whatever the case under test needs.
    ///
    /// Not documented in `untofu --help`: it is a seam, not a feature.
    static var apiBase: String {
        ProcessInfo.processInfo.environment["UNTOFU_GITHUB_API"] ?? "https://api.github.com"
    }

    struct RemoteFile {
        let name: String
        let url: URL
    }

    /// Every family slug in the catalogue, cached on disk for a week.
    ///
    /// This exists for document scanning. Reading fonts out of an iWork file is
    /// heuristic — the model is compressed protobuf with no schema — and asking
    /// "does this string look like a font name?" accepts slide layout names,
    /// gradient presets and UUIDs alike. Roughly seventy false positives from
    /// one empty Keynote deck, which would exhaust an hour's API budget.
    ///
    /// Asking instead "is this a family the catalogue actually has?" is exact,
    /// and costs a handful of requests once a week rather than one per guess.
    /// The catalogue as last written to disk, without the freshness check and
    /// without ever reaching the network. Returns nil when it has never been
    /// fetched.
    ///
    /// Callers that only want to ask "is this plausibly a real family?" use this
    /// rather than `knownFamilySlugs()`, which blocks on GitHub when the cache
    /// has expired. A slightly stale catalogue is a perfectly good answer to
    /// that question; a surprise network round trip is not.
    static func cachedFamilySlugs() -> Set<String>? {
        let cacheFile = Cache.root.appendingPathComponent("families.json")
        guard let data = try? Data(contentsOf: cacheFile),
              let cached = try? JSONDecoder().decode(FamilyCache.self, from: data)
        else { return nil }
        return Set(cached.slugs)
    }

    static func knownFamilySlugs() -> Set<String> {
        let cacheFile = Cache.root.appendingPathComponent("families.json")
        if let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(FamilyCache.self, from: data),
           Date().timeIntervalSince(cached.fetched) < 7 * 24 * 3600 {
            return Set(cached.slugs)
        }

        var slugs = Set<String>()
        // The contents API caps out well below the ~1800 families in ofl/, so
        // walk the git tree instead, which returns a directory whole.
        guard let rootData = get(URL(string: "\(apiBase)/repos/google/fonts/git/trees/main")!).data,
              let root = try? JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              let tree = root["tree"] as? [[String: Any]]
        else { return [] }

        for entry in tree {
            guard let path = entry["path"] as? String, licenseDirs.contains(path),
                  let sha = entry["sha"] as? String,
                  let subData = get(URL(string: "\(apiBase)/repos/google/fonts/git/trees/\(sha)")!).data,
                  let sub = try? JSONSerialization.jsonObject(with: subData) as? [String: Any],
                  let families = sub["tree"] as? [[String: Any]]
            else { continue }
            for family in families where family["type"] as? String == "tree" {
                if let name = family["path"] as? String { slugs.insert(name) }
            }
        }

        guard !slugs.isEmpty else { return [] }
        if let data = try? JSONEncoder().encode(FamilyCache(fetched: Date(), slugs: Array(slugs))) {
            try? data.write(to: cacheFile)
        }
        Log.debug("catalogue: \(slugs.count) families")
        return slugs
    }

    private struct FamilyCache: Codable {
        let fetched: Date
        let slugs: [String]
    }

    /// What `<license>/<slug>/` holds — or why we cannot say.
    static func listing(license: String, slug: String, wanting: String? = nil) -> Availability {
        if let reason = paused { return .unreachable(reason) }

        let api = URL(string: "\(apiBase)/repos/google/fonts/contents/\(license)/\(slug)")!
        let response = get(api)

        if response.status == 403 || response.status == 429 {
            // Cap the pause. GitHub's reset can be most of an hour away, and a
            // font agent that stops trying for fifty minutes is hard to tell
            // apart from a broken one; fifteen is long enough to stop burning
            // the budget and short enough that reopening a document works.
            let wait = min(response.retryAfter ?? 900, 900)
            pause(max(wait, 60), because: "GitHub rate limit — unauthenticated callers get "
                                        + "60 requests/hour; set GITHUB_TOKEN to raise it")
            return .unreachable("rate limited")
        }
        if response.status == 0 {
            // No HTTP status at all: DNS, no route, TLS, timeout. Short pause,
            // because a laptop that just woke up recovers in seconds.
            pause(60, because: "cannot reach GitHub")
            return .unreachable("network unreachable")
        }
        guard response.status != 404 else { return .absent }
        guard let data = response.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .unreachable("GitHub answered \(response.status)") }

        let files: [RemoteFile] = json.compactMap { entry in
            guard entry["type"] as? String == "file",
                  let name = entry["name"] as? String,
                  let href = entry["download_url"] as? String,
                  let url = URL(string: href),
                  name.hasSuffix(".ttf") || name.hasSuffix(".otf")
            else { return nil }
            return RemoteFile(name: name, url: url)
        }
        // An empty directory is a real answer: the family is not served here.
        return files.isEmpty ? .absent : .found(order(files, wanting: wanting))
    }

    /// Variable fonts first — a single `Family[wght].ttf` carries every named
    /// instance, so one download usually satisfies the whole family. Then plain
    /// upright faces, since an italic request still names the roman family.
    /// Files in the order most likely to satisfy `wanted`, best first.
    ///
    /// Variable fonts stay ahead of statics because one of them usually carries
    /// the whole family. What changed is the italic rule: it was a flat "italics
    /// last", which is right when an upright was asked for and exactly backwards
    /// when an italic was. Only eight files are ever downloaded
    /// (`Fetcher.maxDownloadsPerAttempt`), so in a large static-only family —
    /// Poppins ships 18 files, Kanit 18 — the italic the user actually asked for
    /// sat past the cut and the font was reported unavailable while being
    /// perfectly fetchable.
    private static func order(_ files: [RemoteFile], wanting wanted: String? = nil) -> [RemoteFile] {
        let wantsItalic = wanted.map(isItalicName) ?? false
        return files.sorted { a, b in
            func rank(_ f: RemoteFile) -> Int {
                let italic = f.name.contains("Italic") || f.name.contains("italic")
                if f.name.contains("[") { return italic == wantsItalic ? 0 : 1 }
                return italic == wantsItalic ? 2 : 3
            }
            let (ra, rb) = (rank(a), rank(b))
            return ra == rb ? a.name < b.name : ra < rb
        }
    }

    /// Whether a requested name is asking for an italic.
    ///
    /// "Oblique" counts — several families spell it that way — but a family
    /// whose NAME contains the word must not be dragged in, so this looks only
    /// at the style half, after the first hyphen or space.
    static func isItalicName(_ psName: String) -> Bool {
        let style = psName.split(separator: "-", maxSplits: 1).dropFirst().first
            ?? psName.split(separator: " ", maxSplits: 1).dropFirst().first
            ?? ""
        let lowered = style.lowercased()
        return lowered.contains("italic") || lowered.contains("oblique")
    }

    /// One downloaded file, or why it did not arrive.
    enum Download {
        case saved(URL)
        /// Could not be fetched or stored. Nothing about the font follows.
        case unreachable(String)
    }

    /// Downloads one file.
    ///
    /// Returns a reason rather than a bare nil, and the caller must treat every
    /// reason as inconclusive. Asking the global `paused` flag afterwards was
    /// not good enough: a 5xx from raw.githubusercontent.com, or a 200 with an
    /// empty body behind a captive portal, arms no pause — so the caller saw
    /// nil, found `paused` nil, and concluded the font does not exist.
    static func download(_ file: RemoteFile, to directory: URL) -> Download {
        if let reason = paused { return .unreachable(reason) }

        let response = get(file.url)
        if response.status == 403 || response.status == 429 {
            let wait = min(response.retryAfter ?? 900, 900)
            pause(max(wait, 60), because: "GitHub rate limit while downloading")
            return .unreachable("rate limited")
        }
        if response.status == 0 {
            pause(60, because: "cannot reach GitHub")
            return .unreachable("network unreachable")
        }
        guard (200..<300).contains(response.status) else {
            // 5xx during an incident, 451, a proxy's 407 — all transient, none
            // of them evidence. Pause briefly so a whole document's worth of
            // files does not each rediscover it.
            pause(60, because: "GitHub answered \(response.status) for a download")
            return .unreachable("GitHub answered \(response.status)")
        }
        guard let data = response.data, !data.isEmpty else {
            return .unreachable("empty response body")
        }

        let destination = directory.appendingPathComponent(file.name)
        do {
            try data.write(to: destination)
            return .saved(destination)
        } catch {
            // A full disk is not a fact about the catalogue.
            return .unreachable("could not write \(file.name): \(error.localizedDescription)")
        }
    }

    // MARK: - Transport

    private struct Response {
        let data: Data?
        let status: Int
        /// Seconds to wait, from `Retry-After` or `x-ratelimit-reset`. GitHub
        /// tells us exactly when the budget refills; guessing is unnecessary.
        var retryAfter: TimeInterval?
    }

    /// What asking about a family actually told us.
    ///
    /// The distinction this type exists to preserve: "we asked and this family
    /// is not there" is a fact about the catalogue, while "we could not ask" is
    /// a fact about the network. Collapsing them — which this client did until
    /// 0.4.6, returning nil for all of it — meant a rate limit or a dropped
    /// connection told the user a perfectly available font did not exist, and
    /// suppressed retrying it for six hours.
    enum Availability {
        case found([RemoteFile])
        /// Asked, answered, not there.
        case absent
        /// Could not ask. Carries why, for the log.
        case unreachable(String)
    }

    /// When the whole client should stop asking, and why.
    ///
    /// Global rather than per-font, because a rate limit is a property of the
    /// API and not of the name being looked up. Without this, a document with
    /// thirty missing fonts spends thirty more requests discovering thirty
    /// times that it is still rate limited.
    private static let backoffLock = NSLock()
    private static var backoffUntil: Date?
    private static var backoffReason = ""

    static func pause(_ seconds: TimeInterval, because reason: String) {
        backoffLock.lock()
        let until = Date().addingTimeInterval(seconds)
        if (backoffUntil.map { until > $0 }) ?? true {
            backoffUntil = until
            backoffReason = reason
            Log.warn("pausing GitHub lookups for \(Int(seconds))s: \(reason)")
        }
        backoffLock.unlock()
    }

    /// Non-nil while the client is backed off, carrying the reason.
    static var paused: String? {
        backoffLock.lock(); defer { backoffLock.unlock() }
        guard let until = backoffUntil else { return nil }
        guard until > Date() else { backoffUntil = nil; return nil }
        return backoffReason
    }

    /// For tests: forget any backoff.
    static func resumeNow() {
        backoffLock.lock(); backoffUntil = nil; backoffLock.unlock()
    }

    private static func get(_ url: URL) -> Response {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("untofu (+https://github.com/taggie313/untofu)",
                         forHTTPHeaderField: "User-Agent")
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var payload: Data?
        var status = 0
        let done = DispatchSemaphore(value: 0)
        var retryAfter: TimeInterval?
        URLSession.shared.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            status = http?.statusCode ?? 0
            if (200..<300).contains(status) { payload = data }
            if let seconds = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init) {
                retryAfter = seconds
            } else if let reset = (http?.value(forHTTPHeaderField: "x-ratelimit-reset")).flatMap(TimeInterval.init) {
                retryAfter = max(0, reset - Date().timeIntervalSince1970)
            }
            if let error { Log.debug("request failed \(url.lastPathComponent): \(error.localizedDescription)") }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 35)
        return Response(data: payload, status: status, retryAfter: retryAfter)
    }
}
