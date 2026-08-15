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

    /// Homebrew names formula services `homebrew.mxcl.<formula>`.
    static let brewLabel = "homebrew.mxcl.untofu"

    static var isLoaded: Bool { loaded(label) }
    static var brewServiceLoaded: Bool { loaded(brewLabel) }

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
            "KeepAlive": true,
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
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return }
        if kill(pid, SIGHUP) == 0 { Log.debug("signalled running agent (pid \(pid))") }
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
