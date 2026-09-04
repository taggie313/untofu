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

    static func install() throws {
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
            "ProgramArguments": [installedBinary.path, "run"],
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

    static func uninstall() throws {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
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
