import Foundation

/// The few things untofu has to remember about what the user has decided.
///
/// Deliberately not `UserDefaults`: the agent has no bundle identifier of its
/// own, so its defaults would land in a domain named after whatever argv[0]
/// happened to be. A file beside the cache is easier to inspect, easier to
/// delete, and survives being launched by three different mechanisms.
final class Preferences {
    struct Stored: Codable {
        /// Whether untofu may check for a new version without being asked.
        ///
        /// Off. An update check is a request to a server carrying the fact that
        /// this Mac runs this tool, and nothing about a font manager justifies
        /// making that happen behind the user's back. Every dialog offers the
        /// check as a button; this only decides whether it also happens on its own.
        var updateChecksAllowed = false

        /// Whether the one-time offer to turn that on has been made. Asked once,
        /// never again, whatever the answer.
        var updateOfferMade = false

        /// Names the user has asked never to hear about again, lowercased.
        var suppressedNames: [String] = []

        var lastUpdateCheck: Date?
        var lastSeenVersion: String?
    }

    private let lock = NSLock()
    private var stored: Stored
    private let url: URL

    init(url: URL = Cache.root.appendingPathComponent("preferences.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    /// Read a value.
    func value<T>(_ path: KeyPath<Stored, T>) -> T {
        lock.lock(); defer { lock.unlock() }
        return stored[keyPath: path]
    }

    /// Mutate and persist in one step, so no caller can change a setting and
    /// forget to write it.
    func update(_ change: (inout Stored) -> Void) {
        lock.lock()
        change(&stored)
        let snapshot = stored
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Suppression

    func isSuppressed(_ psName: String) -> Bool {
        let key = psName.lowercased()
        lock.lock(); defer { lock.unlock() }
        return stored.suppressedNames.contains(key)
    }

    func suppress(_ names: [String]) {
        update { stored in
            for name in names where !stored.suppressedNames.contains(name.lowercased()) {
                stored.suppressedNames.append(name.lowercased())
            }
        }
    }

    func unsuppressAll() {
        update { $0.suppressedNames = [] }
    }
}
