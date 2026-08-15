import Darwin
import Foundation

let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("-") }
let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
Log.verbose = flags.contains("--verbose") || flags.contains("-v")

let cache = Cache()

func usage() -> Never {
    print("""
    untofu — supplies missing fonts to any macOS app, on demand.

    USAGE
      untofu run                Run the provider in the foreground (launchd uses this).
      untofu install            Install and start the login agent.
      untofu uninstall          Stop and remove the login agent.
      untofu status             Show hook availability, agent state, cache size.
      untofu fetch <PSName>     Resolve and cache one PostScript name now.
      untofu list               List cached faces.
      untofu verify             Drop index entries whose file has gone missing.
      untofu policy <pid>       Show how a given process would be treated.
      untofu notify-test        Post a sample notification banner.
      untofu dialog-test        Show the "couldn't find it" dialog.

    OPTIONS
      -v, --verbose                Log resolution steps.
      -q, --quiet                  Say nothing at all (run only).
          --banner                 Announce successes as a transient banner
                                   instead of a dialog needing dismissal.
          --no-dialog              Suppress the "couldn't find it" dialog.
          --fetch-for-browsers     Also fetch for browsers. Off by default: a CSS
                                   font stack is a preference list the page is
                                   built to fall through, so fetching for one is
                                   noise, and every miss would put a font name a
                                   web page chose into a request to GitHub.

    ENVIRONMENT
      GITHUB_TOKEN                 Raises the google/fonts listing rate limit above
                                   the unauthenticated 60 requests/hour.
    """)
    exit(positional.isEmpty ? 1 : 0)
}

if flags.contains("--version") {
    print("untofu \(Build.version)")
    exit(0)
}

switch positional.first ?? "" {

case "version":
    print("untofu \(Build.version)")

case "run":
    let quiet = flags.contains("--quiet") || flags.contains("-q")
    let noDialog = quiet || flags.contains("--no-dialog")
    let style: Notifier.Style = flags.contains("--banner") ? .banner : .dialog
    let provider = Provider(cache: cache,
                            notifier: quiet ? nil : Notifier(style: style),
                            reporter: noDialog ? nil : UnresolvedReporter(),
                            fetchForBrowsers: flags.contains("--fetch-for-browsers"))
    guard provider.start() else {
        Log.warn("""
        CTFontManagerCreateFontRequestRunLoopSource is unavailable on this system.

        This API has been deprecated since macOS 11 and annotated "will be removed
        in a future release". Its removal is the expected end of this tool's life,
        not a bug in it. Missing fonts will now behave exactly as they did before
        untofu was installed. Run `untofu uninstall` to remove the agent.
        """)
        exit(3)
    }

    try? String(getpid()).write(to: LaunchAgent.pidURL, atomically: true, encoding: .utf8)
    atexit { try? FileManager.default.removeItem(at: LaunchAgent.pidURL) }

    // Signal-source style, so the handler is a normal closure rather than
    // async-signal-safe C.
    signal(SIGHUP, SIG_IGN)
    let hangup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
    hangup.setEventHandler {
        cache.reload()
        Log.info("index reloaded — \(cache.entries.count) face(s)")
    }
    hangup.resume()

    Log.info("untofu running — \(cache.entries.count) face(s) cached")
    provider.run()

case "install":
    do {
        try LaunchAgent.install()
        print("Installed and started \(LaunchAgent.label).")
        print("  binary: \(LaunchAgent.installedBinary.path)")
        print("  plist:  \(LaunchAgent.plistURL.path)")
        print("  log:    \(LaunchAgent.logURL.path)")
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

case "uninstall":
    try? LaunchAgent.uninstall()
    print("Removed \(LaunchAgent.label). Cached fonts in \(Cache.root.path) were left alone.")

case "status":
    let probe = Provider(cache: cache)
    let hookAvailable = probe.start()
    probe.stop()
    print("version:    \(Build.version)")
    print("hook:       \(hookAvailable ? "available" : "UNAVAILABLE (deprecated API removed)")")
    print("agent:      \(LaunchAgent.isLoaded ? "loaded" : "not loaded")")
    print("brew svc:   \(LaunchAgent.brewServiceLoaded ? "loaded" : "not loaded")")
    if LaunchAgent.isLoaded && LaunchAgent.brewServiceLoaded {
        print("            ⚠︎ both are loaded — they will race over the same cache.")
        print("              Stop one: `brew services stop untofu` or `untofu uninstall`.")
    }
    print("cache:      \(cache.entries.count) face(s) in \(Cache.root.path)")
    print("unresolved: \(cache.unresolvedNames.count) name(s) in negative cache")
    print("browsers:   cache reads only, no fetching (--fetch-for-browsers to change)")
    if !hookAvailable { exit(3) }

case "fetch":
    guard positional.count > 1 else {
        FileHandle.standardError.write(Data("fetch needs a PostScript name, e.g. RalewayRoman-Regular\n".utf8))
        exit(1)
    }
    let name = positional[1]
    if Fetcher.fetch(psName: name, into: cache) {
        LaunchAgent.reloadRunningAgent()
        print("cached \(name)")
    } else {
        print("could not resolve \(name)")
        exit(1)
    }

case "list":
    let entries = cache.entries
    if entries.isEmpty {
        print("nothing cached yet")
    } else {
        for entry in entries { print("  \(entry.psName)  ->  \(entry.file)") }
        print("\(entries.count) face(s)")
    }

case "policy":
    guard positional.count > 1, let pid = pid_t(positional[1]) else {
        FileHandle.standardError.write(Data("policy needs a pid, e.g. `untofu policy 74039`\n".utf8))
        exit(1)
    }
    let path = RequesterPolicy.executablePath(pid) ?? "(cannot inspect this process)"
    let decision = RequesterPolicy.forProcess(pid)
    print("pid \(pid)")
    print("  \(path)")
    print("  \(decision == .serveFromCacheOnly ? "cache reads only — treated as a browser" : "may fetch")")

case "verify":
    let dropped = cache.verify()
    print(dropped == 0 ? "index is clean" : "dropped \(dropped) stale entr\(dropped == 1 ? "y" : "ies")")

case "notify-test":
    Notifier.post(title: "untofu",
                  subtitle: "Fetched 3 missing fonts",
                  body: "Raleway, Lora, and Playfair Display — reopen the document to see them.")
    print("Posted a sample banner. If nothing appeared, check System Settings > "
        + "Notifications > Script Editor — banners posted this way are attributed there.")

case "dialog-test":
    let reporter = UnresolvedReporter()
    reporter.record(psName: positional.count > 1 ? positional[1] : "HelveticaNeueLTPro-Bd")
    if positional.count > 2 { reporter.record(psName: positional[2]) }
    // The reporter debounces, then blocks on the dialog; hold the process open.
    Thread.sleep(forTimeInterval: TimeInterval(600))

default:
    usage()
}
