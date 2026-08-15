import Foundation

enum Shell {
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
        return (process.terminationStatus,
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Runs an AppleScript and returns its result. Used for the few pieces of UI
    /// a non-bundled launchd agent can still put on screen.
    @discardableResult
    static func osascript(_ script: String) -> (status: Int32, output: String) {
        run("/usr/bin/osascript", ["-e", script])
    }

    /// AppleScript string literals take the same escapes as C, and the prompts
    /// here are multi-line, so real newlines have to become the two-character
    /// escape. Order matters: backslashes first, or the escapes we add get
    /// escaped in turn.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
    }
}
