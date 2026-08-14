import Darwin
import Foundation

/// launchd plumbing for running the provider as a login agent.
enum LaunchAgent {
    static let label = "net.elusive.fontfetch"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The agent runs a private copy rather than the build-directory binary, so
    /// a `swift build --clean` or a moved checkout does not silently break login.
    static var installedBinary: URL {
        Cache.root.appendingPathComponent("bin/fontfetch")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/fontfetch.log")
    }

    static var isLoaded: Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    static func install() throws {
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

    static var pidURL: URL { Cache.root.appendingPathComponent("fontfetch.pid") }

    // MARK: - Helpers

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
