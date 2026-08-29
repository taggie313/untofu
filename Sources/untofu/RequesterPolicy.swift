import AppKit
import CFontProvider
import Darwin
import Foundation

/// What a given process is allowed to make untofu do.
///
/// Browsers are the reason this exists, and the mechanism is narrower than it
/// first looks. A plain `font-family` stack does *not* reach this hook: that is
/// resolved by matching against already-enumerated families. What does reach it
/// is `@font-face { src: local("Product Sans"), url(...) }` — the standard trick
/// for "use the installed copy if the visitor happens to have one, otherwise
/// download it". `local()` is an explicit by-name lookup, which is exactly what
/// the font-request hook intercepts.
///
/// Measured, rather than assumed: Chromium routes `local()` through a CoreText
/// by-name lookup and fires the hook; Safari/WebKit does not. So on a Chromium
/// browser every site offering a local() fallback asks the system for that font
/// by name, whether or not the visitor has it — and the page renders perfectly
/// well when the answer is no, because the `url()` source is right there.
///
/// Fetching for them is wrong three ways. It is traffic for pages that did not
/// need it; unobtainable brand fonts pop a dialog at someone who is only
/// browsing; and every unresolved name becomes a GitHub API call, which quietly
/// leaks the shape of a person's browsing to a third party.
///
/// So browsers get the cache read-only. A hit is still served — that costs
/// nothing, touches no network and leaks nothing — but a miss never becomes a
/// download and never opens a dialog.
enum RequesterPolicy {
    case serveAndFetch
    case serveFromCacheOnly

    /// Substrings matched case-insensitively against a process's executable
    /// path. Helper processes carry their browser's name in the path (Chrome's
    /// renderer lives under `Google Chrome.app/Contents/Frameworks/...`), so
    /// path matching catches them without naming each one.
    ///
    /// Short names are anchored with `.app/` so that, for example, "Arc" cannot
    /// match some unrelated path containing those three letters.
    private static let browserMarkers = [
        "google chrome", "chromium", "thorium",
        "safari", "com.apple.webkit",       // also catches embedded WebKit views
        "firefox", "plugin-container",
        "microsoft edge", "brave browser", "vivaldi", "opera",
        "/arc.app/", "/orion.app/", "/zen.app/", "/zen browser.app/",
    ]

    static func forProcess(_ pid: pid_t) -> RequesterPolicy {
        guard let path = executablePath(pid) else {
            // Unknown process — usually one that exited between asking and our
            // looking. Fetching is the useful default; the negative cache and
            // request de-duplication bound the damage if it is ever wrong.
            return .serveAndFetch
        }
        let lowered = path.lowercased()
        return browserMarkers.contains(where: lowered.contains) ? .serveFromCacheOnly : .serveAndFetch
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard ff_process_path(pid, &buffer, buffer.count) else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// What to call the requesting application when telling the user about it.
    ///
    /// The executable name is the fallback rather than the answer: plenty of
    /// applications run their work in a helper whose binary is called something
    /// nobody would recognise, and "Keynote" is a more useful thing to read than
    /// the name of the process that happened to lay out the text.
    static func displayName(_ pid: pid_t) -> String? {
        if let named = NSRunningApplication(processIdentifier: pid)?.localizedName,
           !named.isEmpty { return named }
        guard let path = executablePath(pid) else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Bundle identifier of the requesting application, when it has one.
    ///
    /// This is what a miss report carries: it says which application ran into
    /// the problem without saying anything about where this user keeps their
    /// software, which the executable path would.
    static func bundleIdentifier(_ pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
