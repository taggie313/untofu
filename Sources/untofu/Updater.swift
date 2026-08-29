import AppKit
import Foundation

/// Asks GitHub whether there is a newer release than this one.
///
/// Never runs on its own unless the user has explicitly allowed it. An update
/// check is a request to a server that discloses this Mac runs this tool, and a
/// font agent has no business making that request unasked. So: every dialog
/// carries a button that runs one check, on the spot, because the user pressed
/// it; and the one-time offer at first launch is the only route to it happening
/// automatically.
///
/// Homebrew users are covered by `brew upgrade` and mostly do not need this. The
/// audience is everyone who installed the signed .pkg, for whom there is
/// otherwise no route by which a fix ever reaches them.
enum Updater {
    static let releasesAPI = URL(string:
        "https://api.github.com/repos/taggie313/untofu/releases/latest")!
    static let releasesPage = URL(string:
        "https://github.com/taggie313/untofu/releases/latest")!

    /// How long to leave between automatic checks, once allowed.
    static let interval: TimeInterval = 7 * 24 * 3600

    enum Outcome {
        case upToDate(current: String)
        case updateAvailable(latest: String, current: String, notes: String?)
        case failed(String)

        var headline: String {
            switch self {
            case .upToDate(let current):
                return "untofu \(current) is the latest version."
            case .updateAvailable(let latest, let current, _):
                return "untofu \(latest) is available. You have \(current)."
            case .failed(let why):
                return "Could not check for updates: \(why)"
            }
        }
    }

    /// Blocking. Background queue only.
    static func check() -> Outcome {
        var request = URLRequest(url: releasesAPI, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("untofu/\(Build.version)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: String?
        var status = 0

        URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { failure = error.localizedDescription }
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 15) == .success else {
            return .failed("the request timed out")
        }
        if let failure { return .failed(failure) }
        guard status == 200 else { return .failed("GitHub answered \(status)") }
        guard let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed("GitHub's answer could not be read") }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = (json["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return isNewer(latest, than: Build.version)
            ? .updateAvailable(latest: latest, current: Build.version, notes: notes)
            : .upToDate(current: Build.version)
    }

    /// Numeric component-wise comparison. "0.10.0" is newer than "0.9.0", which
    /// a string comparison gets backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0
            let right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }

    /// The one-time offer to let update checks happen unprompted.
    ///
    /// Made once, ever, whatever the answer — `updateOfferMade` records that it
    /// was asked, not what was said. Declining leaves every dialog's "Check for
    /// Updates" button working, so saying no costs the user nothing except the
    /// automatic part.
    ///
    /// Delayed rather than shown the instant the agent launches: at login this
    /// process starts alongside everything the user actually wants to look at,
    /// and a modal about a font tool arriving in the middle of that is the wrong
    /// first impression for something whose whole pitch is invisibility.
    static let offerDelay: TimeInterval = 90

    static func offerIfNeeded(_ preferences: Preferences) {
        guard !preferences.value(\.updateOfferMade) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + offerDelay) {
            guard !preferences.value(\.updateOfferMade) else { return }

            let alert = NSAlert()
            alert.messageText = "Should untofu check for updates on its own?"
            alert.informativeText = """
            untofu never contacts a server unless you ask it to. If you turn this \
            on it will ask GitHub once a week whether a newer version exists, which \
            tells GitHub that this Mac runs untofu.

            Either way, every untofu dialog has a "Check for Updates" button that \
            checks on the spot. You will only be asked this once.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Check Automatically")
            alert.addButton(withTitle: "Only When I Ask")

            let allowed = alert.runModal() == .alertFirstButtonReturn
            preferences.update { stored in
                stored.updateOfferMade = true
                stored.updateChecksAllowed = allowed
            }
            Log.info("update checks \(allowed ? "allowed" : "left off") by the user")
        }
    }

    /// Runs a check only if the user allowed it and one is due. Returns nil
    /// otherwise, having touched nothing.
    static func scheduledCheck(_ preferences: Preferences) -> Outcome? {
        guard preferences.value(\.updateChecksAllowed) else { return nil }
        if let last = preferences.value(\.lastUpdateCheck),
           Date().timeIntervalSince(last) < interval { return nil }

        let outcome = check()
        preferences.update { stored in
            stored.lastUpdateCheck = Date()
            if case .updateAvailable(let latest, _, _) = outcome { stored.lastSeenVersion = latest }
        }
        return outcome
    }
}
