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
