import Darwin
import Foundation

/// A "this font could not be found" report, sent only when the user presses the
/// button that sends it.
///
/// The point is to learn which fonts people actually get stuck on, so a future
/// release can resolve them — a cataloguing gap, an application asking under a
/// spelling the resolver does not try, or a font sitting unregistered on the
/// disk in a directory nobody thought to look in.
///
/// What it deliberately does not carry: no document name, no file path, no user
/// or machine identifier, nothing that would let two reports be tied to the same
/// person. The exact JSON below is what is sent, and the dialog shows it before
/// sending. That transparency is the reason the payload is a plain dictionary
/// rendered to a string rather than something assembled inside URLSession.
struct MissReport: Codable {
    /// The name the application asked for.
    let font: String
    /// Bundle identifier of the requesting application, e.g. com.apple.iWork.Keynote.
    /// The identifier rather than the path: it says which application without
    /// saying anything about where this user keeps their software.
    let app: String?
    let untofuVersion: String
    let macosVersion: String
    /// Whether an unregistered copy was found on this Mac. A miss that is really
    /// "we had it and did not look properly" is a different bug from a miss that
    /// is "nobody publishes this font", and only this field tells them apart.
    let foundLocally: Bool

    enum CodingKeys: String, CodingKey {
        case font, app
        case untofuVersion = "untofu_version"
        case macosVersion = "macos_version"
        case foundLocally = "found_locally"
    }

    static let endpoint = URL(string: "https://untofu.elusive.net/api/report")!

    static func build(font: String, requesterPID: pid_t?, foundLocally: Bool) -> MissReport {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return MissReport(
            font: font,
            app: requesterPID.flatMap { RequesterPolicy.bundleIdentifier($0) },
            untofuVersion: Build.version,
            macosVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            foundLocally: foundLocally)
    }

    /// Exactly what will be transmitted, formatted for a human to read first.
    var previewJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Blocking. Background queue only. Returns nil on success, else why not.
    func send() -> String? {
        guard let body = try? JSONEncoder().encode(self) else { return "could not encode the report" }

        var request = URLRequest(url: MissReport.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("untofu/\(Build.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var failure: String?
        URLSession.shared.dataTask(with: request) { _, response, error in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { failure = error.localizedDescription }
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 15) == .success else { return "the request timed out" }
        if let failure { return failure }
        guard (200..<300).contains(status) else { return "the server answered \(status)" }
        Log.info("reported unresolved font: \(font)")
        return nil
    }
}
