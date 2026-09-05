import Darwin
import Foundation

/// launchd plumbing for running the provider as a login agent.
enum LaunchAgent {
    static let label = "net.elusive.untofu"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The agent runs a private copy rather than the build-directory binary, so
    /// a `swift build --clean` or a moved checkout does not silently break login.
    static var installedBinary: URL {
        Cache.root.appendingPathComponent("bin/untofu")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/untofu.log")
    }

    /// Everywhere this tool's log might be, because that depends on how it was
    /// installed and `logURL` only knows about one of them.
    ///
    /// `logURL` is where the standalone agent writes, because that is the plist
    /// this code generates. A Homebrew-managed service writes to the prefix's
    /// `var/log` instead, named by Homebrew's own formula DSL. Reading history
    /// from `logURL` alone therefore found nothing at all on a machine running
    /// the Homebrew build — which is every machine that installed it the
    /// recommended way.
    static var logCandidates: [URL] {
        // Same seam as UNTOFU_GITHUB_API: the seeding logic is only interesting
        // for the lines it must NOT count, and there is no way to exercise that
        // against a real log without waiting for one to contain the right
        // mistakes. Not documented in --help; it is a seam, not a feature.
        if let override = ProcessInfo.processInfo.environment["UNTOFU_LOG"], !override.isEmpty {
            return [URL(fileURLWithPath: override)]
        }
        var paths = [logURL]
        // Derive the prefix from where this binary actually lives, so an
        // unusual Homebrew prefix is handled without guessing, then fall back
        // to the two standard ones.
        let executable = URL(fileURLWithPath: currentExecutablePath())
        var walk = executable
        while walk.pathComponents.count > 2 {
            walk.deleteLastPathComponent()
            if walk.lastPathComponent == "opt" || walk.lastPathComponent == "Cellar" {
                let prefix = walk.deletingLastPathComponent()
                paths.append(prefix.appendingPathComponent("var/log/untofu.log"))
                break
            }
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            paths.append(URL(fileURLWithPath: "\(prefix)/var/log/untofu.log"))
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0.path).inserted }
    }

    /// What Homebrew calls its service for this formula.
    ///
    /// Two labels, because Homebrew renamed the scheme: it was
    /// `homebrew.mxcl.<formula>` and is now `sh.brew.<formula>`. Checking only
    /// the old one silently broke two things on this machine — `untofu status`
    /// reported "brew svc: not loaded" while the service was plainly running,
    /// and, worse, `install` stopped refusing to add a second agent beside a
    /// Homebrew-managed one. That guard exists because two agents race over one
    /// cache and clobber each other's staging; a hardcoded label that ages out
    /// turns a deliberate safety check into a no-op without a word.
    static let brewLabels = ["sh.brew.untofu", "homebrew.mxcl.untofu"]

    /// The label actually in use, for messages that name it.
    static var brewLabel: String {
        brewLabels.first(where: loaded) ?? brewLabels[0]
    }

    static var isLoaded: Bool { loaded(label) }
    static var brewServiceLoaded: Bool { brewLabels.contains(where: loaded) }

    private static func loaded(_ label: String) -> Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    /// Flags `install` will carry into the agent it registers.
    ///
    /// The generated plist ran `untofu run` with nothing after it, so every
    /// option given to `install` was accepted in silence and then dropped:
    /// `untofu install --no-dialog` registered an agent that shows dialogs.
    /// Anything not on this list cannot be honoured by a background agent and
    /// is refused rather than ignored.
    static let installableRunFlags: Set<String> = [
        "-q", "--quiet", "-v", "--verbose", "--banner", "--no-dialog",
        "--no-local", "--fetch-for-browsers",
    ]

    static func install(runFlags: [String] = []) throws {
        // Two agents would race over one cache — concurrent providers competing
        // to answer the same font request and clobbering each other's staging
        // directories. Refuse rather than quietly create the second one.
        guard !brewServiceLoaded else {
            throw Failure("""
            A Homebrew-managed service (\(brewLabel)) is already loaded.
            Installing a second agent would have the two race over the same cache.
            Use `brew services restart untofu` instead, or run
            `brew services stop untofu` first if you want the standalone agent.
            """)
        }

        let binDir = installedBinary.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installedBinary)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: currentExecutablePath()),
                                         to: installedBinary)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedBinary.path, "run"] + runFlags,
            "RunAtLoad": true,
            // Restart on a crash, but NOT on a clean exit. `untofu run` exits 0
            // when the CoreText hook is gone — the documented end of this
            // tool's life — and plain `KeepAlive: true` would turn that into a
            // permanent respawn loop, relaunching every ten seconds forever on
            // a macOS where the tool cannot work at all.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL)

        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])   // may not be loaded
        let result = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            throw Failure("launchctl bootstrap failed (\(result.status)): \(result.output)")
        }
    }

    /// Where the .pkg installer puts its plist — the system domain, root-owned,
    /// under the same label as the standalone agent.
    static var pkgPlistURL: URL {
        URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist")
    }

    /// Whether Homebrew has this formula installed, service running or not.
    static var brewInstalled: Bool {
        if brewServiceLoaded { return true }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        return brewLabels.contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).plist").path)
        }
    }

    /// What an uninstall actually managed to do.
    struct UninstallOutcome {
        var hadOwnPlist = false
        var removedOwnPlist = false
        var stopped = false
        var homebrewRemains = false
        var pkgRemains = false
        var complete: Bool { !homebrewRemains && !pkgRemains }
    }

    /// Removes the agent this code installs — and only that one.
    ///
    /// It used to `throws` without ever throwing (the bootout status was
    /// discarded with `_ =`, the removal with `try?`), and the caller printed
    /// "Removed …" unconditionally. So a Homebrew user — the install path the
    /// README recommends first — was told the agent was gone while it went on
    /// running and went on starting at every login. A .pkg user got a message
    /// that was briefly true: the shared label means bootout does stop it, but
    /// the plist it deletes is in ~/Library while the .pkg's is in /Library, so
    /// launchd brings it back at the next login.
    ///
    /// Neither can be removed from here: a Homebrew service belongs to `brew`,
    /// and the .pkg's plist is root-owned. Reporting them is the whole fix.
    @discardableResult
    static func uninstall() -> UninstallOutcome {
        var outcome = UninstallOutcome()
        outcome.hadOwnPlist = FileManager.default.fileExists(atPath: plistURL.path)
        outcome.stopped = run("/bin/launchctl",
                              ["bootout", "gui/\(getuid())/\(label)"]).status == 0
        if outcome.hadOwnPlist {
            try? FileManager.default.removeItem(at: plistURL)
            outcome.removedOwnPlist = !FileManager.default.fileExists(atPath: plistURL.path)
        }
        outcome.homebrewRemains = brewInstalled
        outcome.pkgRemains = FileManager.default.fileExists(atPath: pkgPlistURL.path)
        return outcome
    }

    /// Nudges a running agent to re-read the on-disk index.
    static func reloadRunningAgent() {
        if let text = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, kill(pid, SIGHUP) == 0 {
            Log.debug("signalled running agent (pid \(pid))")
            return
        }

        // The pid file lives in the cache directory, so anything that clears the
        // cache orphans it — and then every CLI change that needs the agent to
        // notice would silently do nothing. That is exactly how a `folders
        // --rescan` came to record 581 faces while the agent went on serving
        // 544, reporting success the whole time.
        let mine = getpid()
        for pid in runningAgents() where pid != mine {
            if kill(pid, SIGHUP) == 0 { Log.debug("signalled running agent (pid \(pid), found by name)") }
        }
    }

    /// PIDs of agents belonging to this user, for when the pid file is gone.
    private static func runningAgents() -> [pid_t] {
        let result = run("/usr/bin/pgrep", ["-u", String(getuid()), "-f", "untofu run"])
        guard result.status == 0 else { return [] }
        return result.output.split(whereSeparator: { $0.isNewline || $0 == " " })
            .compactMap { pid_t($0) }
    }

    static var pidURL: URL { Cache.root.appendingPathComponent("untofu.pid") }

    // MARK: - Helpers

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        Shell.run(tool, arguments)
    }

    private static func currentExecutablePath() -> String {
        var size = UInt32(4096)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            return String(cString: buffer)
        }
        return CommandLine.arguments[0]
    }
}
