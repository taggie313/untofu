import Darwin
import Foundation

/// Notices when another process changes the state the agent serves from.
///
/// The agent used to learn about such changes only by being signalled, and twice
/// that went wrong in the same silent way: the CLI updated the record, reported
/// success, and the agent went on serving a stale index. Once because the pid
/// file lived in the cache directory and was cleared along with it, so the signal
/// was never sent; once because the test suite restored the files with no way to
/// tell the agent. Both times `untofu status` — a fresh process, reading from
/// disk — reported the correct thing while the running agent did the wrong one,
/// which is the hardest shape of bug to notice.
///
/// So the state is polled, and the signal becomes a second path rather than the
/// only one.
///
/// **Polled rather than watched, deliberately.** The obvious implementation is a
/// `DispatchSource` vnode watch, and it was the first one written here. It does
/// not work: modifying a file in place does not change its directory, so a watch
/// on the directory sees creates, deletes and renames but not writes — it caught
/// this agent's own atomic snapshot replaces and missed the plain `cp` that
/// restores a file over an existing one, which is precisely the case that
/// produced the bug. Watching each file as well means re-arming every one of
/// them after every atomic replace, since a rename leaves the old descriptor
/// pointing at an unlinked inode. Two `stat` calls every couple of seconds cost
/// nothing and cannot miss a mutation shape.
final class StateWatcher {
    private let paths: [URL]
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "net.elusive.untofu.statewatch",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var fingerprints: [String: String] = [:]

    /// Frequent enough that a `untofu folders --rescan` feels immediate even if
    /// its signal is lost, rare enough to be free.
    static let interval: TimeInterval = 2

    init(watching paths: [URL], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        stop()
        fingerprints = current()          // the state at startup is not a change

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + StateWatcher.interval,
                       repeating: StateWatcher.interval,
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.current()
            guard now != self.fingerprints else { return }
            self.fingerprints = now
            self.onChange()
        }
        timer.resume()
        self.timer = timer
        Log.debug("state watch: polling \(paths.count) file(s) every "
                + "\(Int(StateWatcher.interval))s")
        return true
    }

    /// Size and modification date, which is enough to see any write, replace or
    /// deletion. Deliberately not a content hash: this runs on a timer and the
    /// record is ~150 KB.
    private func current() -> [String: String] {
        var out: [String: String] = [:]
        for url in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  let modified = attrs[.modificationDate] as? Date
            else { out[url.lastPathComponent] = "absent"; continue }
            out[url.lastPathComponent] = "\(size)@\(modified.timeIntervalSince1970)"
        }
        return out
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }
}
