import Foundation

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var verbose = false

    static func info(_ message: String) { emit("", message) }
    static func warn(_ message: String) { emit("warning: ", message) }
    static func debug(_ message: String) { if verbose { emit("debug: ", message) } }

    private static func emit(_ prefix: String, _ message: String) {
        FileHandle.standardError.write(
            Data("\(formatter.string(from: Date())) \(prefix)\(message)\n".utf8))
    }
}
