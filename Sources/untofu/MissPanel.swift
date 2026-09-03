import AppKit
import Foundation

/// The window untofu shows when it could not find a font.
///
/// It replaces an `osascript choose from list`, which had three problems worth
/// fixing. Its prompt is clamped to a fixed height, so the explanation was cut
/// off mid-sentence — "Track the font down and Tr…". Its OK button is dead until
/// a row is selected, so the obvious first click does nothing. And because
/// osascript runs the script, the dialog is attributed to Script Editor rather
/// than to untofu, which is also where its notification permissions live.
///
/// Shown as a floating panel rather than a modal alert. The user is in the
/// middle of reading a document; this is information about that document, not an
/// interruption that should seize the keyboard. It stays until dismissed —
/// a transient banner is too easy to miss when the point is that what is on
/// screen is wrong.
final class MissPanel: NSObject, NSWindowDelegate {

    private static let contentWidth: CGFloat = 460
    private static let margin: CGFloat = 20

    /// Somewhere a font might be found, and how to search there for one.
    private struct Destination {
        let title: String
        let detail: String
        let url: (String) -> URL?
    }

    private static let destinations: [Destination] = [
        Destination(title: "Adobe Fonts",
                    detail: "Included with a Creative Cloud plan") {
            URL(string: "https://fonts.adobe.com/search?query=\(encode($0))")
        },
        Destination(title: "Search the web",
                    detail: "Often the quickest route to a foundry") {
            URL(string: "https://www.google.com/search?q=\(encode("\"\($0)\" font"))")
        },
        Destination(title: "MyFonts",
                    detail: "Commercial licensing") {
            URL(string: "https://www.myfonts.com/search/\(encode($0))/")
        },
        Destination(title: "Fontspring",
                    detail: "Commercial licensing") {
            URL(string: "https://www.fontspring.com/search?q=\(encode($0))")
        },
    ]

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: - State

    private let names: [String]
    private let requester: String?
    private let requesterBundle: String?
    private let preferences: Preferences
    private let local: LocalFonts?
    /// Held so the panel is not deallocated the moment `present` returns.
    private static var onScreen: Set<MissPanel> = []

    private var window: NSWindow!
    private var suppressCheckbox: NSButton!
    private var statusLabel: NSTextField!
    private var reportButton: NSButton!
    private var updateButton: NSButton!

    private var primary: String { names[0] }

    init(names: [String], requester: String?, requesterBundle: String?,
         preferences: Preferences, local: LocalFonts? = nil) {
        self.names = names
        self.requester = requester
        self.requesterBundle = requesterBundle
        self.preferences = preferences
        self.local = local
        super.init()
    }

    // MARK: - Presentation

    /// Must be called on the main thread.
    func present() {
        precondition(Thread.isMainThread, "MissPanel touches AppKit")
        build()
        MissPanel.onScreen.insert(self)
        window.center()
        // Ordered front without activating. The user is reading something; this
        // is a remark about what they are reading, not a demand for the keyboard.
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        MissPanel.onScreen.remove(self)
    }

    /// Renders the panel's content to a PNG without showing it.
    ///
    /// Exists because the alternative for checking layout is a screenshot, which
    /// needs a Screen Recording grant the agent has no reason to hold.
    ///
    /// One known blind spot: macOS draws bezeled buttons through
    /// `_NSCoreHostingView<AppKitButton>`, a SwiftUI host with no `drawRect:`,
    /// so they come out blank here however the snapshot is taken — cacheDisplay
    /// and PDF alike. Everything else is faithful, and `-v` dumps the frame of
    /// every view so the buttons can at least be checked for position and size.
    func snapshot(to url: URL, appearance name: NSAppearance.Name) {
        precondition(Thread.isMainThread, "MissPanel touches AppKit")
        build()
        window.appearance = NSAppearance(named: name)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()

        // Via PDF rather than cacheDisplay. Text fields, checkboxes and bezeled
        // buttons all draw through layers that a cacheDisplay on a never-shown
        // window comes back empty for — the first attempt at this produced the
        // four link buttons and nothing else. dataWithPDF walks drawRect: for
        // the whole tree instead, which every control implements.
        if Log.verbose { MissPanel.dumpFrames(view, depth: 0) }

        let bounds = view.bounds
        let pdf = view.dataWithPDF(inside: bounds)
        guard let drawn = NSImage(data: pdf) else { return }

        let scale = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * scale, pixelsHigh: Int(bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // The PDF is transparent where the window's own background would be, so
        // paint that first or the review is of text on a checkerboard.
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        drawn.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func dumpFrames(_ view: NSView, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let kind = String(describing: type(of: view))
        let f = view.frame
        Log.debug("\(pad)\(kind) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))"
                + (view.isHidden ? " HIDDEN" : ""))
        for sub in view.subviews { dumpFrames(sub, depth: depth + 1) }
    }

    // MARK: - Construction

    private func build() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: MissPanel.margin, left: MissPanel.margin,
                                          bottom: 16, right: MissPanel.margin)
        content.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(header())
        content.addArrangedSubview(explanation())
        content.addArrangedSubview(separator())
        content.addArrangedSubview(lookHereLabel())
        for destination in MissPanel.destinations {
            content.addArrangedSubview(destinationRow(destination))
        }
        content.addArrangedSubview(copyRow())
        content.addArrangedSubview(separator())
        content.addArrangedSubview(footer())

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: MissPanel.contentWidth, height: 100),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "untofu"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: MissPanel.contentWidth),
        ])
        panel.contentView = container
        panel.setContentSize(container.fittingSize)
        window = panel
    }

    private func header() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "character.square",
                             accessibilityDescription: "missing font")
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let headline = label(
            names.count == 1 ? "Couldn't find \(primary)"
                             : "Couldn't find \(names.count) fonts",
            font: .systemFont(ofSize: 15, weight: .semibold))
        text.addArrangedSubview(headline)

        // Naming the application is the difference between a message about
        // nothing in particular and a message about the window in front of you.
        let subject = names.count == 1 ? "it" : "them"
        let who = requester.map { "\($0) asked for \(subject)." }
                  ?? "An application asked for \(subject)."
        text.addArrangedSubview(label(who, font: .systemFont(ofSize: 12),
                                      color: .secondaryLabelColor))

        if names.count > 1 {
            let list = label(names.map { "•  \($0)" }.joined(separator: "\n"),
                             font: .systemFont(ofSize: 12), color: .labelColor)
            text.addArrangedSubview(list)
        }

        row.addArrangedSubview(icon)
        row.addArrangedSubview(text)
        return row
    }

    private func explanation() -> NSView {
        // Short on purpose. The old dialog spent ninety words explaining what a
        // commercial font is, and the last third of it was truncated away anyway.
        let text = """
        Your document is showing a substitute. untofu searched Google Fonts and \
        the fonts already on this Mac, so this is most likely a commercial or \
        private font. Install it the usual way and it will resolve from then on.
        """
        return label(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    }

    private func lookHereLabel() -> NSView {
        let suffix = names.count > 1 ? " for \(primary)" : ""
        return label("Where to look\(suffix):",
                     font: .systemFont(ofSize: 12, weight: .semibold))
    }

    private func destinationRow(_ destination: Destination) -> NSView {
        let button = NSButton()
        button.title = destination.title
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 12)
        button.target = self
        button.action = #selector(openDestination(_:))
        button.identifier = NSUserInterfaceItemIdentifier(destination.title)
        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(button)
        row.addArrangedSubview(label(destination.detail, font: .systemFont(ofSize: 11),
                                     color: .tertiaryLabelColor))
        return row
    }

    /// Copying the name sits with the places to search rather than in the action
    /// row: it is the thing you do *before* searching somewhere this panel does
    /// not list, and the action row was crowded enough to clip once the update
    /// button relabels itself.
    private func copyRow() -> NSView {
        let button = NSButton()
        button.title = names.count == 1 ? "Copy the name" : "Copy all \(names.count) names"
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 12)
        button.target = self
        button.action = #selector(copyNames)
        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(button)
        row.addArrangedSubview(label("To search somewhere else", font: .systemFont(ofSize: 11),
                                     color: .tertiaryLabelColor))
        return row
    }

    private func footer() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10

        suppressCheckbox = NSButton(checkboxWithTitle:
            names.count == 1 ? "Don't tell me about this font again"
                             : "Don't tell me about these fonts again",
            target: self, action: #selector(toggleSuppression))
        suppressCheckbox.font = .systemFont(ofSize: 12)
        column.addArrangedSubview(suppressCheckbox)

        statusLabel = label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        statusLabel.isHidden = true
        column.addArrangedSubview(statusLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        reportButton = NSButton(title: "Report this…", target: self,
                                action: #selector(report))
        reportButton.bezelStyle = .rounded
        reportButton.font = .systemFont(ofSize: 12)

        updateButton = NSButton(title: "Check for Updates", target: self,
                                action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        updateButton.font = .systemFont(ofSize: 12)

        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.font = .systemFont(ofSize: 12)

        // A plain NSView has no intrinsic width and hugs at the default priority,
        // so it settles at zero and every button ends up packed on the left.
        // Hugging below everything else is what makes it take the slack.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
                                                       for: .horizontal)

        buttons.addArrangedSubview(reportButton)
        buttons.addArrangedSubview(updateButton)
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(done)

        // The enclosing stacks align leading, so nothing stretches on its own and
        // the row would be only as wide as its buttons — leaving the spacer no
        // slack to take. The content width is fixed, so pin to it outright.
        buttons.distribution = .fill
        buttons.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(
            equalToConstant: MissPanel.contentWidth - 2 * MissPanel.margin).isActive = true
        return column
    }

    // MARK: - Helpers

    private func label(_ text: String, font: NSFont,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 400
        return field
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func show(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.isHidden = false
        window.setContentSize(window.contentView!.fittingSize)
    }

    // MARK: - Actions

    @objc private func openDestination(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue,
              let destination = MissPanel.destinations.first(where: { $0.title == title }),
              let url = destination.url(primary)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyNames() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        show(names.count == 1 ? "Copied “\(primary)” to the clipboard."
                              : "Copied \(names.count) names to the clipboard.")
    }

    @objc private func toggleSuppression() {
        if suppressCheckbox.state == .on {
            preferences.suppress(names)
            show("untofu will stay quiet about "
               + (names.count == 1 ? "this font." : "these fonts.")
               + " Undo with `untofu unsuppress`.")
        } else {
            // Un-ticking has to actually undo it, or the checkbox is a lie the
            // moment someone changes their mind before closing the window.
            preferences.update { stored in
                let removing = Set(names.map { $0.lowercased() })
                stored.suppressedNames.removeAll { removing.contains($0) }
            }
            show("untofu will keep telling you about "
               + (names.count == 1 ? "this font." : "these fonts."))
        }
    }

    @objc private func dismiss() {
        window.close()
    }

    // MARK: - Phoning home, only when asked

    @objc private func report() {
        // A relative on disk, not the name itself: by now the exact name has
        // already failed every lookup, so asking after it would answer no every
        // time. Whether the *family* was here all along is the question worth
        // sending.
        let relative = local?.relative(of: primary)
        let report = MissReport.build(font: primary, requesterBundle: requesterBundle,
                                      foundLocally: relative != nil)

        // Shown before it is sent, in full. A button that quietly transmits
        // something is a different feature from one that offers to.
        NSApp.activate(ignoringOtherApps: true)
        guard MissPanel.confirmationAlert(for: report).runModal() == .alertFirstButtonReturn
        else { return }

        reportButton.isEnabled = false
        show("Sending…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let failure = report.send()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reportButton.isEnabled = failure != nil
                self.show(failure.map { "Could not send the report: \($0)" }
                          ?? "Thanks — reported. \(self.primary) will be looked into.")
            }
        }
    }

    /// The confirmation, built in one place so `untofu dialog-preview report`
    /// shows exactly what ships rather than a copy that can drift out of step.
    static func confirmationAlert(for report: MissReport) -> NSAlert {
        let confirm = NSAlert()
        confirm.messageText = "Report that untofu couldn't find \(report.font)?"
        confirm.informativeText = """
        This is sent to untofu.elusive.net so the font can be looked into for a \
        future release. It carries no document name, no file path, and nothing \
        identifying you or this Mac. Exactly this is sent:

        \(report.previewJSON)
        """
        confirm.alertStyle = .informational
        confirm.icon = Icon.image()
        confirm.addButton(withTitle: "Send Report")
        confirm.addButton(withTitle: "Cancel")
        return confirm
    }

    @objc private func checkForUpdates() {
        updateButton.isEnabled = false
        show("Checking…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Updater.check()
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateButton.isEnabled = true
                self.show(outcome.headline)
                if case .updateAvailable = outcome {
                    self.updateButton.title = "Open Releases"
                    self.updateButton.action = #selector(self.openReleases)
                }
            }
        }
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(Updater.releasesPage)
    }
}
