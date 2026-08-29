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

        /// Whether to index font stashes that macOS gates behind a permission
        /// prompt — Downloads, and the Office and Adobe user containers.
        ///
        /// Off. Reaching into them from a background agent makes macOS
        /// interrupt with "untofu would like to access files in your Downloads
        /// folder", which is precisely the kind of unexplained dialog this tool
        /// exists to remove. `untofu folders --allow` turns it on in the
        /// foreground, where the prompt answers something the user just did.
        var searchPersonalFolders = false
    }

    private let lock = NSLock()
    private var stored: Stored
    private let url: URL

    init(url: URL = Cache.root.appendingPathComponent("preferences.json")) {
        self.url = url
        stored = Preferences.read(url) ?? Stored()
    }

    /// Decoding has to mirror the encoder exactly, and getting that wrong was
    /// silent and total: the encoder writes dates as ISO8601, the decoder
    /// defaulted to expecting a number, and so the moment an update check
    /// recorded `lastUpdateCheck` the whole file stopped decoding. Every
    /// setting reverted to its default on the next read — the folder opt-in,
    /// the update consent, every suppressed font name — while the file on disk
    /// still plainly said otherwise.
    ///
    /// It fails loudly now. A preferences file that exists but cannot be read
    /// is a bug, and answering with defaults as though the user had never
    /// chosen anything is the worst possible way to report it.
    private static func read(_ url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Stored.self, from: data)
        } catch {
            Log.warn("could not read \(url.lastPathComponent) (\(error)); "
                   + "using defaults, and your settings will be overwritten if "
                   + "anything changes one. Delete the file to start clean.")
            return nil
        }
    }

    /// Re-reads the file, for a long-running agent whose settings were changed
    /// by a CLI invocation in another process.
    ///
    /// Without this the agent answers from whatever it read at launch, and a
    /// preference change appears to do nothing until the next restart —
    /// `untofu folders --allow` would index the newly-permitted directories in
    /// the CLI process, hand the agent a SIGHUP, and watch it rescan with the
    /// old setting and write a snapshot that drops them again.
    func reload() {
        guard let decoded = Preferences.read(url) else { return }
        lock.lock()
        stored = decoded
        lock.unlock()
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
