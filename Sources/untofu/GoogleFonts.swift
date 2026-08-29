import Foundation

/// Minimal client for the google/fonts repository.
///
/// Everything here performs blocking network I/O and must never be called from
/// the provider callback — see Provider.handle for the split.
enum GoogleFonts {
    /// google/fonts partitions families by license directory.
    static let licenseDirs = ["ofl", "apache", "ufl"]

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
        guard let rootData = get(URL(string: "https://api.github.com/repos/google/fonts/git/trees/main")!).data,
              let root = try? JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              let tree = root["tree"] as? [[String: Any]]
        else { return [] }

        for entry in tree {
            guard let path = entry["path"] as? String, licenseDirs.contains(path),
                  let sha = entry["sha"] as? String,
                  let subData = get(URL(string: "https://api.github.com/repos/google/fonts/git/trees/\(sha)")!).data,
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

    /// Font files in `<license>/<slug>/`, or nil when that directory does not exist.
    static func listing(license: String, slug: String) -> [RemoteFile]? {
        let api = URL(string: "https://api.github.com/repos/google/fonts/contents/\(license)/\(slug)")!
        let response = get(api)

        if response.status == 403 || response.status == 429 {
            Log.warn("GitHub API rate limit hit. Unauthenticated callers get 60 requests/hour; "
                   + "set GITHUB_TOKEN to raise it.")
            return nil
        }
        guard let data = response.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let files: [RemoteFile] = json.compactMap { entry in
            guard entry["type"] as? String == "file",
                  let name = entry["name"] as? String,
                  let href = entry["download_url"] as? String,
                  let url = URL(string: href),
                  name.hasSuffix(".ttf") || name.hasSuffix(".otf")
            else { return nil }
            return RemoteFile(name: name, url: url)
        }
        return files.isEmpty ? nil : order(files)
    }

    /// Variable fonts first — a single `Family[wght].ttf` carries every named
    /// instance, so one download usually satisfies the whole family. Then plain
    /// upright faces, since an italic request still names the roman family.
    private static func order(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { a, b in
            func rank(_ f: RemoteFile) -> Int {
                if f.name.contains("[") { return f.name.contains("Italic") ? 1 : 0 }
                if f.name.contains("Italic") { return 3 }
                return 2
            }
            let (ra, rb) = (rank(a), rank(b))
            return ra == rb ? a.name < b.name : ra < rb
        }
    }

    static func download(_ file: RemoteFile, to directory: URL) -> URL? {
        guard let data = get(file.url).data, !data.isEmpty else { return nil }
        let destination = directory.appendingPathComponent(file.name)
        do {
            try data.write(to: destination)
            return destination
        } catch {
            Log.warn("could not write \(file.name): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Transport

    private struct Response {
        let data: Data?
        let status: Int
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
        URLSession.shared.dataTask(with: request) { data, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { payload = data }
            if let error { Log.debug("request failed \(url.lastPathComponent): \(error.localizedDescription)") }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 35)
        return Response(data: payload, status: status)
    }
}
