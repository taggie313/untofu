import AppKit
import Darwin
import Foundation

let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("-") }
let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
Log.verbose = flags.contains("--verbose") || flags.contains("-v")

let cache = Cache()
let preferences = Preferences()

/// Keeps a preview's coalescing object alive; see `dialog-preview`.
var previewHolder: AnyObject?

/// What any process other than the deliberate, user-invoked walk may do about
/// the permission-gated stashes: serve what was already recorded, never look.
func gatedPolicy() -> LocalFonts.GatedPolicy {
    preferences.value(\.searchPersonalFolders) ? .trustSnapshot : .exclude
}

func usage() -> Never {
    print("""
    untofu — supplies missing fonts to any macOS app, on demand.

    USAGE
      untofu run                Run the provider in the foreground (launchd uses this).
      untofu install            Install and start the login agent.
      untofu uninstall          Stop and remove the login agent.
      untofu status             Show hook availability, agent state, cache size.
      untofu scan <file>...     Read documents and fetch the fonts they need,
                                so the first open is already correct.
      untofu fetch <PSName>     Resolve and cache one PostScript name now.
      untofu list               List cached faces.
      untofu verify             Drop index entries whose file has gone missing.
      untofu policy <pid>       Show how a given process would be treated.
      untofu explain <PSName>   Show how a font name would be classified, without
                                fetching anything.
      untofu local              List fonts found on this Mac that no application
                                has registered. --rebuild re-reads every file
                                rather than trusting the stored index.
      untofu folders            Show which font locations are searched. --allow
                                opts into the permission-gated ones, --rescan
                                re-reads them, --deny stops.
      untofu update             Check now whether a newer untofu exists.
      untofu suppressed         List fonts you asked not to be told about.
      untofu unsuppress [name]  Start being told about them again. With no name,
                                clears the whole list.
      untofu notify-test        Post a sample notification banner.
      untofu dialog-test        Show the "couldn't find it" dialog.

    OPTIONS
      -v, --verbose                Log resolution steps.
      -q, --quiet                  Say nothing at all (run only).
          --banner                 Announce successes as a transient banner
                                   instead of a dialog needing dismissal.
          --no-dialog              Suppress the "couldn't find it" dialog.
          --no-local               Do not serve fonts found on this Mac outside the
                                   installed font library. See LOCAL FONTS below.
          --fetch-for-browsers     Also fetch for browsers. Off by default: a CSS
                                   font stack is a preference list the page is
                                   built to fall through, so fetching for one is
                                   noise, and every miss would put a font name a
                                   web page chose into a request to GitHub.

    LOCAL FONTS
      Most "missing" fonts are already on the disk and merely registered to
      nobody: Office ships 251 faces inside its application bundles, Adobe syncs
      activated Adobe Fonts into a hidden CoreSync directory, and Office caches
      fonts it downloads on demand. untofu indexes those at startup and serves
      them, which is the only path fast enough to fix the document that asked.

      Only locations macOS does not gate are searched by default. Office's
      cloud cache, Adobe's CoreSync directory and ~/Downloads sit behind a
      permission prompt, and a background agent provoking one unasked is the
      sort of dialog untofu exists to remove. `untofu folders --allow` opts in.

      Whether a font bundled with one application may be used by another is a
      question for its licence, not for this tool. `--no-local` turns it off, and
      `untofu local` shows exactly what would be served and where it came from.

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
    let local = flags.contains("--no-local") ? nil : LocalFonts()
    // Whether anything will ever want to draw: true when either the success
    // notifier or the unresolved panel is enabled.
    let wantsUI = !quiet || !noDialog
    let provider = Provider(cache: cache, local: local,
                            notifier: quiet ? nil : Notifier(style: style),
                            reporter: noDialog ? nil : UnresolvedReporter(preferences: preferences,
                                                                          local: local),
                            fetchForBrowsers: flags.contains("--fetch-for-browsers"))
    guard provider.start() else {
        Log.warn("""
        CTFontManagerCreateFontRequestRunLoopSource is unavailable on this system.

        This API has been deprecated since macOS 11 and annotated "will be removed
        in a future release". Its removal is the expected end of this tool's life,
        not a bug in it. Missing fonts will now behave exactly as they did before
        untofu was installed. Run `untofu uninstall` to remove the agent.
        """)
        // Zero, deliberately. This is the tool reaching the end of its life, not
        // failing at something — and the launchers keep the agent alive only
        // across *unsuccessful* exits, so a non-zero status here would have
        // launchd restart it every ten seconds forever, writing that paragraph
        // to the log each time. `untofu status` still exits 3, because there the
        // caller asked a question and wants the answer in $?.
        exit(0)
    }

    try? String(getpid()).write(to: LaunchAgent.pidURL, atomically: true, encoding: .utf8)
    atexit { try? FileManager.default.removeItem(at: LaunchAgent.pidURL) }

    // Watch the state directory, so a change made by a CLI invocation is noticed
    // whether or not the signal below arrives. It twice did not: once because
    // the pid file lives in this very directory and was cleared along with it,
    // once because the test suite restored the files with no way to say so. Both
    // times the agent went on serving a stale index while `untofu status` — a
    // fresh process reading from disk — reported the truth.
    let watcher = StateWatcher(watching: [LocalFonts.snapshotURL,
                                          Cache.root.appendingPathComponent("preferences.json"),
                                          Cache.root.appendingPathComponent("index.json")]) {
        preferences.reload()
        cache.reload()
        if local?.adoptSnapshot(gated: gatedPolicy()) == true {
            Log.info("state changed on disk — \(cache.entries.count) cached face(s), "
                   + "\(local?.faceCount ?? 0) local face(s)")
        }
    }
    if !watcher.start() {
        Log.debug("state watch unavailable; relying on SIGHUP alone")
    }

    // Signal-source style, so the handler is a normal closure rather than
    // async-signal-safe C.
    signal(SIGHUP, SIG_IGN)
    let hangup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
    hangup.setEventHandler {
        // Preferences first: the CLI signals us precisely because it changed
        // something, and refreshing against the setting we booted with would
        // rescan with the old answer and persist that.
        preferences.reload()
        cache.reload()
        let personal = preferences.value(\.searchPersonalFolders)
        local?.refresh(gated: gatedPolicy())
        Log.info("reloaded — \(cache.entries.count) cached face(s), "
               + "\(local?.faceCount ?? 0) local face(s)"
               + (personal ? " including Downloads and app containers" : ""))
    }
    hangup.resume()

    // Off the main thread: the runloop must start accepting font requests now,
    // not once several hundred files have been parsed. Requests arriving during
    // the scan fall through to the fetch path, which is the behaviour that
    // shipped before the local index existed.
    if let local {
        DispatchQueue.global(qos: .utility).async {
            local.refresh(gated: gatedPolicy())
            if let scan = local.summary {
                // The read count is the interesting half. A first run reads
                // 1.35 GB and takes half a minute; every later one reads nothing
                // and takes milliseconds, and the log should make plain which
                // of those just happened.
                Log.info("local index: \(scan.faces) unregistered face(s) from "
                       + "\(scan.files) walked file(s) in "
                       + "\(String(format: "%.2f", scan.duration))s "
                       + (scan.parsed == 0
                          ? "(all reused, nothing read)"
                          : "(read \(scan.parsed) file(s), "
                            + String(format: "%.0f", Double(scan.bytesRead) / 1_048_576) + " MB)")
                       + (scan.trusted > 0
                          ? " + \(scan.trusted) trusted from the recorded index" : ""))
            }
        }
    }

    // Warm the family catalogue.
    //
    // It is the veto that stops a leading run of whole words being mistaken for a
    // proprietary family, and without it that rule stands down entirely — by
    // design, because suppressing on a guess is worse than a spurious dialog. The
    // catch was that nothing ever fetched it: `knownFamilySlugs()` was called
    // only by `untofu scan`, so a user who never scans a document never has a
    // catalogue, the rule never engages, and every Office document goes on
    // producing "couldn't find this font" dialogs for HoloLens MDL2 Assets and
    // the rest. That is exactly the complaint that started this work, and the
    // suppression shipped in 0.4.5 only ever worked here because testing had
    // scanned a document and left a catalogue behind.
    //
    // A handful of requests, once a week, on a background queue, from a tool
    // whose entire purpose is fetching fonts from that same host: it discloses
    // nothing that an actual fetch would not.
    DispatchQueue.global(qos: .utility).async {
        let hadOne = GoogleFonts.cachedFamilySlugs() != nil
        let catalogue = GoogleFonts.knownFamilySlugs()
        if catalogue.isEmpty {
            Log.debug("could not warm the family catalogue; the word rule stays stood down")
        } else if !hadOne {
            Log.info("family catalogue warmed — \(catalogue.count) families")
        }
    }

    // Nothing here contacts a server unless the user has said it may. The offer
    // is made once and needs an interface to make it through.
    if wantsUI && AppHost.hasWindowServer {
        Updater.offerIfNeeded(preferences)
        DispatchQueue.global(qos: .background).async {
            if let outcome = Updater.scheduledCheck(preferences) {
                Log.info("update check: \(outcome.headline)")
            }
        }
    }

    // An NSApplication only when there is a user to talk to and a window server
    // to talk through. Headless and --quiet runs keep the plain runloop: the
    // provider does not need AppKit, and touching NSApplication with no window
    // server is fatal rather than merely useless.
    // withExtendedLifetime: neither call returns, but nothing refers to the
    // watcher afterwards, and ARC is free to release it the moment its last use
    // passes — the same way a released reporter silently stopped a dialog from
    // ever appearing.
    if wantsUI && AppHost.hasWindowServer {
        Log.info("untofu running — \(cache.entries.count) face(s) cached")
        withExtendedLifetime(watcher) { AppHost.run(provider: provider) }
    }
    Log.info("untofu running — \(cache.entries.count) face(s) cached, no interface")
    withExtendedLifetime(watcher) { provider.run() }

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
    let statusLocal = LocalFonts()
    statusLocal.refresh(gated: gatedPolicy())
    print("local:      \(statusLocal.faceCount) unregistered face(s) on this Mac "
        + "(`untofu local` to see them)")
    print("unresolved: \(cache.unresolvedNames.count) name(s) in negative cache")
    print("browsers:   cache reads only, no fetching (--fetch-for-browsers to change)")
    if preferences.value(\.searchPersonalFolders) {
        print("folders:    including Downloads and app containers"
            + (LocalFonts.recordHasGatedEntries
               ? " (`untofu folders`)"
               : " — but nothing recorded; run `untofu folders --rescan`"))
    } else {
        print("folders:    excluding Downloads and app containers (`untofu folders`)")
    }
    print("suppressed: \(preferences.value(\.suppressedNames).count) name(s) you asked not to hear about")
    let updatePolicy = preferences.value(\.updateChecksAllowed)
        ? "allowed, weekly" : "only when you ask"
    print("updates:    \(updatePolicy)"
        + (preferences.value(\.updateOfferMade) ? "" : " (you have not been asked yet)"))
    if !hookAvailable { exit(3) }

case "scan":
    guard positional.count > 1 else {
        FileHandle.standardError.write(Data("scan needs a file, e.g. Deck.key\n".utf8))
        exit(1)
    }
    // The catalogue lookup allows 60 requests an hour unauthenticated, and the
    // iWork reader is heuristic enough to turn up the occasional non-font. Cap
    // the damage a single scan can do and say so rather than silently stopping.
    let scanBudget = 15
    var attempted = 0
    var fetchedAny = false
    let catalogue = GoogleFonts.knownFamilySlugs()
    if catalogue.isEmpty {
        FileHandle.standardError.write(Data("could not read the Google Fonts catalogue; is the network up?\n".utf8))
        exit(1)
    }

    func report(_ name: String, _ note: String) {
        print("    \(name.padding(toLength: max(name.count, 30), withPad: " ", startingAt: 0))\(note)")
    }

    for path in positional.dropFirst() {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("\(path): no such file"); continue
        }
        let (format, names) = Scanner.fonts(in: url)
        print("\(url.lastPathComponent)  [\(format)]")
        if names.isEmpty { print("    no font references found"); continue }

        // OOXML and PDF name fonts exactly, so a name the catalogue does not
        // have is worth reporting — it is probably a commercial font the user
        // needs to know about. The iWork reader guesses, so its misses are just
        // noise and get counted rather than listed.
        let precise = (format != .iWork)
        var discarded = 0

        for name in names {
            if Scanner.isAlreadyAvailable(name) { report(name, "already installed"); continue }
            if cache.path(for: name) != nil     { report(name, "already cached");    continue }
            if Resolver.isKnownProprietary(name) { report(name, "skipped, proprietary"); continue }

            // The question is not "does this look like a font?" but "is this a
            // family the catalogue actually has?" — exact, and free once the
            // catalogue is cached.
            guard let family = Resolver.familyCandidates(for: name).first(where: { catalogue.contains($0) }) else {
                if precise { report(name, "not on Google Fonts") } else { discarded += 1 }
                continue
            }
            if flags.contains("--dry-run")    { report(name, "would fetch (\(family))"); continue }
            guard attempted < scanBudget else { report(name, "skipped, scan budget reached"); continue }
            attempted += 1
            // Fetch by the matched family, not the raw string: iWork strings
            // arrive with protobuf framing bytes stuck to them ("Lora-Regularb"),
            // which no font answers to.
            if Fetcher.fetch(psName: family, into: cache) {
                fetchedAny = true
                report(name, "fetched (\(family))")
            } else {
                report(name, "not on Google Fonts")
            }
        }
        if discarded > 0 {
            print("    (\(discarded) other string\(discarded == 1 ? "" : "s") examined and discarded — "
                + "iWork font references are inferred, not declared)")
        }
    }
    // A running agent holds its index in memory, so without this the fonts we
    // just cached would not be served until it restarted.
    if fetchedAny { LaunchAgent.reloadRunningAgent() }

case "fetch":
    guard positional.count > 1 else {
        FileHandle.standardError.write(Data("fetch needs a PostScript name, e.g. RalewayRoman-Regular\n".utf8))
        exit(1)
    }
    let name = positional[1]
    switch Fetcher.resolve(psName: name, into: cache) {
    case .fetched:
        LaunchAgent.reloadRunningAgent()
        print("cached \(name)")
    case .absent:
        print("could not resolve \(name) — nothing on Google Fonts answers to that name")
        exit(1)
    case .unreachable(let why):
        // Distinct exit code, because these are different questions: 1 means
        // the catalogue does not have it, 2 means nobody asked the catalogue.
        // A script that retries should retry on 2 and not on 1.
        print("could not look up \(name): \(why)")
        if GoogleFonts.paused != nil {
            print("Lookups are paused for a few minutes. `untofu fetch` again after that,")
            print("or set GITHUB_TOKEN to raise the 60-requests-per-hour limit.")
        }
        exit(2)
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

case "explain":
    guard positional.count > 1 else {
        FileHandle.standardError.write(Data("explain needs a font name, e.g. \"Aptos Display\"\n".utf8))
        exit(1)
    }
    // The name the provider would actually work with, so `explain` describes what
    // would really happen rather than what the raw string looks like.
    let rawSubject = positional[1]
    guard let subject = Resolver.normalized(rawSubject) else {
        print("name:        \(rawSubject)")
        print("normalised:  refused — not a usable font name, nothing would be looked up")
        break
    }
    if subject != rawSubject { print("normalised:  \(rawSubject)  ->  \(subject)") }
    print("name:        \(subject)")
    print("words:       \(Resolver.familyWords(for: subject).joined(separator: " · "))")
    print("candidates:  \(Resolver.lookupSlugs(for: subject).joined(separator: ", "))")
    print("display:     \(Resolver.displayFamily(for: subject))")
    print("proprietary: \(Resolver.isKnownProprietary(subject) ? "yes — will not be fetched or reported" : "no")")
    print("cached:      \(cache.path(for: subject) ?? "no")")
    let explainLocal = LocalFonts()
    explainLocal.refresh(gated: gatedPolicy())
    if let path = explainLocal.path(for: subject) {
        print("local:       \(explainLocal.origin(ofPath: path) ?? "on disk") — \(path)")
    } else if let cousin = explainLocal.relative(of: subject) {
        print("local:       this exact name is not here, but \(cousin) is — "
            + "which is what a miss report would say")
    } else {
        print("local:       not found on this Mac outside the installed font library")
    }
    print("retry:       \(cache.shouldAttempt(subject) ? "allowed" : "suppressed, failed within the last 6h")")

case "local":
    let inventory = LocalFonts()
    let searchPersonal = preferences.value(\.searchPersonalFolders)
    let stashes = LocalFonts.stashes(includingPersonal: searchPersonal)
    // Reporting must not prompt: --rescan is the only way to make this walk the
    // gated directories, and it is spelled out in `untofu folders`.
    inventory.refresh(rebuild: flags.contains("--rebuild"),
                      gated: flags.contains("--rescan") && searchPersonal ? .walk : gatedPolicy())

    let walkedGated = flags.contains("--rescan") && searchPersonal
    print("Read directly:")
    for stash in stashes where !stash.needsPermission || walkedGated {
        print("  \(stash.label.padding(toLength: 22, withPad: " ", startingAt: 0))\(stash.url.path)")
    }
    let recorded = stashes.filter { $0.needsPermission && !walkedGated }
    if !recorded.isEmpty {
        print("")
        print("Served from the recorded index, never opened by this process:")
        for stash in recorded {
            print("  \(stash.label.padding(toLength: 22, withPad: " ", startingAt: 0))\(stash.url.path)")
        }
    }

    let listed = inventory.entries
    guard !listed.isEmpty else {
        print("\nNothing found. Every font on this Mac is either installed normally or absent.")
        break
    }

    // Grouped by where it came from, because that is the question a user
    // actually has: not "what is indexed" but "why can Keynote suddenly set
    // Calibri". Names only — the paths are long and the same for whole runs.
    print("")
    for origin in Set(listed.map(\.origin)).sorted() {
        let names = listed.filter { $0.origin == origin }.map(\.psName).sorted()
        print("\(origin) — \(names.count) face(s)")
        for name in names { print("    \(name)") }
    }
    if let scan = inventory.summary {
        print("\n\(scan.faces) face(s) from \(scan.files) file(s) in "
            + String(format: "%.2f", scan.duration) + "s")
        if scan.parsed == 0 {
            print("Every file was already in the index; nothing was read from disk.")
        } else {
            print("Read \(scan.parsed) file(s), "
                + String(format: "%.0f", Double(scan.bytesRead) / 1_048_576) + " MB. "
                + "\(scan.files - scan.parsed) reused from \(LocalFonts.snapshotURL.lastPathComponent).")
        }
        if scan.trusted > 0 {
            print("\(scan.trusted) face-bearing file(s) served from the recorded index "
                + "without opening them — `untofu folders --rescan` re-reads those.")
        }
    }
    print("These are served to any application that asks. `--no-local` turns that off.")

case "folders":
    let gated = LocalFonts.personalStashes
    let on = preferences.value(\.searchPersonalFolders)

    if flags.contains("--allow") || flags.contains("--deny") || flags.contains("--rescan") {
        let allow = !flags.contains("--deny")
        preferences.update { $0.searchPersonalFolders = allow }
        let warmed = LocalFonts()
        if allow {
            print("macOS will ask permission once per location. Answering here is the")
            print("whole point of this command: the agent never asks, because a grant")
            print("given to it does not stick — it re-prompted on a later restart of")
            print("the same binary. So the reading happens here, once, and the agent")
            print("serves what this records without ever opening those directories.\n")
            warmed.refresh(rebuild: true, gated: .walk)
        } else {
            print("Leaving them alone, and dropping them from the index…")
            warmed.refresh(rebuild: true, gated: .exclude)
        }
        if let scan = warmed.summary {
            print("\(scan.faces) face(s) from \(scan.files) file(s)"
                + (scan.parsed > 0 ? ", \(scan.parsed) read" : ""))
        }
        // The agent is holding an index built under the old setting.
        LaunchAgent.reloadRunningAgent()
        break
    }

    print("Searched with no permission needed:")
    for stash in LocalFonts.stashes(includingPersonal: false) {
        print("  \(stash.url.path)")
    }
    print("")
    print(on ? "Also searched (you allowed these):" : "NOT searched — macOS gates these behind a permission prompt:")
    if gated.isEmpty {
        print("  (none of them exist on this Mac)")
    } else {
        for stash in gated { print("  \(stash.url.path)") }
    }
    print("")
    if on {
        print("The agent serves these from what was recorded here; it never opens")
        print("them itself, so it cannot interrupt you at login.")
        if !LocalFonts.recordHasGatedEntries {
            print("")
            print("  ⚠︎ Nothing from them is recorded, so none of it is being served.")
            print("    Run `untofu folders --rescan` to read them.")
        }
        print("")
        print("  untofu folders --rescan   re-read them (after installing new fonts)")
        print("  untofu folders --deny     stop serving them")
    } else {
        print("These are where Office caches fonts it downloads on demand, where")
        print("Creative Cloud keeps activated Adobe Fonts, and where a font you")
        print("downloaded but never installed sits. Worth having — but reaching")
        print("into them makes macOS interrupt you, and a background agent doing")
        print("that unasked is the sort of dialog untofu exists to remove.")
        print("")
        print("  untofu folders --allow    search them; answer the prompts once")
    }

case "update":
    switch Updater.check() {
    case .upToDate(let current):
        print("untofu \(current) is the latest version.")
    case .updateAvailable(let latest, let current, let notes):
        print("untofu \(latest) is available. You have \(current).")
        print("  \(Updater.releasesPage.absoluteString)")
        if let notes { print("\n\(notes)") }
    case .failed(let why):
        FileHandle.standardError.write(Data("could not check for updates: \(why)\n".utf8))
        exit(1)
    }
    preferences.update { $0.lastUpdateCheck = Date() }

case "suppressed":
    let quiet = preferences.value(\.suppressedNames)
    if quiet.isEmpty {
        print("Nothing suppressed. untofu will tell you about every font it cannot find.")
    } else {
        for name in quiet.sorted() { print("  \(name)") }
        print("\(quiet.count) name(s). `untofu unsuppress` to hear about them again.")
    }

case "unsuppress":
    if positional.count > 1 {
        let clearing = Set(positional.dropFirst().map { $0.lowercased() })
        preferences.update { $0.suppressedNames.removeAll { clearing.contains($0) } }
        print("Will report \(positional.dropFirst().joined(separator: ", ")) again.")
    } else {
        let count = preferences.value(\.suppressedNames).count
        preferences.unsuppressAll()
        print(count == 0 ? "Nothing was suppressed." : "Cleared \(count) suppressed name(s).")
    }

case "verify":
    let dropped = cache.verify()
    print(dropped == 0 ? "index is clean" : "dropped \(dropped) stale entr\(dropped == 1 ? "y" : "ies")")

case "notify-test":
    Notifier.post(title: "untofu",
                  subtitle: "Fetched 3 missing fonts",
                  body: "Raleway, Lora, and Playfair Display — reopen the document to see them.")
    print("Posted a sample banner. If nothing appeared, check System Settings > "
        + "Notifications > Script Editor — banners posted this way are attributed there.")

case "report-test":
    // Not in the usage text: proves the client half of the reporting path
    // against whatever endpoint is currently deployed. The collector recognises
    // this font name and deliberately does not store it, so checking that the
    // endpoint works cannot inflate the numbers it exists to report.
    let probe = MissReport.build(font: positional.count > 1 ? positional[1] : "__healthcheck__",
                                 requesterPID: nil, foundLocally: false)
    print("POST \(MissReport.endpoint.absoluteString)")
    print(probe.previewJSON)
    if let failure = probe.send() {
        FileHandle.standardError.write(Data("✗ \(failure)\n".utf8))
        exit(1)
    }
    print("✓ accepted")

case "dialog-preview":
    // Not in the usage text: a development aid for reviewing the wording and
    // appearance of every dialog untofu can put on screen, without having to
    // provoke each one for real.
    let which = positional.count > 1 ? positional[1] : "miss"
    // .accessory, matching the agent. A bundle-less binary asking for .regular
    // has no Dock tile to activate into, and an NSAlert raised under it never
    // makes it to the screen — which is what made this preview look broken while
    // the identical alert from a .accessory process appeared fine.
    let previewApp = NSApplication.shared
    previewApp.setActivationPolicy(.accessory)
    previewApp.activate(ignoringOtherApps: true)

    switch which {
    case "miss", "miss-multi":
        // Held in a variable that outlives this scope. The reporter debounces
        // through a DispatchWorkItem capturing [weak self], so a local constant
        // nothing refers to afterwards is released by ARC before the timer
        // fires and the panel simply never appears.
        let reporter = UnresolvedReporter(preferences: preferences, local: nil)
        previewHolder = reporter
        reporter.record(psName: "Aptos Display", requester: "Keynote", pid: nil)
        if which == "miss-multi" {
            reporter.record(psName: "Segoe UI Semibold")
            reporter.record(psName: "HelveticaNeueLTPro-Bd")
        }
    case "report":
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let sample = MissReport.build(font: "Aptos Display", requesterPID: nil,
                                          foundLocally: true)
            NSApp.activate(ignoringOtherApps: true)
            _ = MissPanel.confirmationAlert(for: sample).runModal()
            exit(0)
        }
    case "update":
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            _ = Updater.offerAlert().runModal()
            exit(0)
        }
    case "success":
        let notifier = Notifier(style: .dialog)
        previewHolder = notifier
        notifier.record(family: "Playfair Display", app: "Keynote")
        notifier.record(family: "Karla", app: "Keynote")
        notifier.record(family: "Lora", app: "Keynote")
    default:
        print("dialog-preview [miss|miss-multi|report|update|success]")
        exit(1)
    }
    previewApp.run()

case "dialog-snapshot":
    // Not in the usage text: a development aid for reviewing the panel's layout
    // without needing a Screen Recording grant to photograph it.
    let snapNames = positional.count > 2 ? Array(positional[2...]) : ["Aptos Display"]
    let snapDir = URL(fileURLWithPath: positional.count > 1 ? positional[1] : ".")
    // finishLaunching, or the window never goes through a real display pass and
    // the snapshot comes back with the link buttons and nothing else.
    let snapApp = NSApplication.shared
    snapApp.setActivationPolicy(.accessory)
    snapApp.finishLaunching()
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua),
                                 ("dark", NSAppearance.Name.darkAqua)] {
        MissPanel(names: snapNames, requester: "Keynote", requesterPID: nil,
                  preferences: preferences)
            .snapshot(to: snapDir.appendingPathComponent("panel-\(suffix).png"),
                      appearance: appearance)
    }
    print("wrote panel-light.png and panel-dark.png to \(snapDir.path)")

case "dialog-test":
    // Needs the same AppKit host the agent runs under, or there is no runloop
    // for the panel to live on and nothing appears.
    let reporter = UnresolvedReporter(preferences: preferences)
    reporter.record(psName: positional.count > 1 ? positional[1] : "HelveticaNeueLTPro-Bd",
                    requester: "Keynote", pid: nil)
    if positional.count > 2 { reporter.record(psName: positional[2]) }
    let host = NSApplication.shared
    host.setActivationPolicy(.regular)
    host.activate(ignoringOtherApps: true)
    host.run()

default:
    usage()
}
