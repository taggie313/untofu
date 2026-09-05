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

    /// Raw bytes, for output that is not text. Document scanning reads
    /// compressed protobuf out of `unzip -p`, which would be mangled by decoding
    /// it as a String first.
    ///
    /// Reads the pipe to the end *before* waiting on the process: doing it the
    /// other way round deadlocks as soon as the output exceeds the pipe buffer,
    /// which a document of any size does.
    /// Most a subprocess may hand back before it is cut off.
    ///
    /// This exists because the caller unzips documents. `readDataToEndOfFile`
    /// has no ceiling, and deflate compresses about 1000:1, so a small archive
    /// decompresses to whatever its author chose. Measured on a release build:
    /// a 407,959-byte .pptx holding one slide of 400 MB of zeros took
    /// `Shell.runData` to 848 MB resident in 1.17 seconds — before a single
    /// regex ran, and roughly 2,000 bytes of memory per byte of input.
    ///
    /// 64 MB, chosen against measurement rather than instinct. The documents on
    /// the machine this was written on decompress to between 67 KB and 551 KB of
    /// XML, so this is over a hundred times the largest real one — and low
    /// enough that the ceiling actually bounds memory. At 256 MB the peak was
    /// still 1.04 GB, because Data doubles its capacity as it grows and the
    /// String conversion then copies the lot again.
    static let maxOutput = 64 * 1024 * 1024

    static func runData(_ tool: String, _ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }

        // Read in chunks so the ceiling can be enforced while the child is still
        // producing, rather than after it has already handed over everything.
        var collected = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }               // EOF
            collected.append(chunk)
            if collected.count > maxOutput {
                Log.warn("\((tool as NSString).lastPathComponent) produced more than "
                       + "\(maxOutput / (1024 * 1024)) MB; stopping it and using what arrived. "
                       + "A document that decompresses to this much is not one this tool can read.")
                process.terminate()
                break
            }
        }
        // Drain whatever is still buffered, or terminate() leaves the child
        // blocked writing into a pipe nobody reads and waitUntilExit hangs.
        if process.isRunning {
            while !handle.availableData.isEmpty {}
        }
        process.waitUntilExit()
        return collected
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
