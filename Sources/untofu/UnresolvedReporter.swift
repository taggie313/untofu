import Foundation

/// Tells the user when a font could not be found, and offers somewhere to look.
///
/// A silent failure is the one case where the user genuinely needs information:
/// the document has already substituted something, untofu cannot help, and
/// nothing on screen explains why. So this is the one place the tool is allowed
/// to interrupt.
///
/// Coalesced like the success banner — a document referencing eight private
/// corporate fonts produces one dialog, not eight. The negative cache then keeps
/// it quiet for six hours per name.
final class UnresolvedReporter {
    /// Slightly longer than the success banner's: a miss costs a full round of
    /// candidate lookups, so misses trickle in more slowly than hits.
    static let quietPeriod: TimeInterval = 4.0

    private let queue = DispatchQueue(label: "net.elusive.untofu.unresolved")
    private var pending: [String] = []
    private var scheduled: DispatchWorkItem?

    func record(psName: String) {
        queue.async {
            if !self.pending.contains(psName) { self.pending.append(psName) }
            self.scheduled?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            self.scheduled = work
            self.queue.asyncAfter(deadline: .now() + UnresolvedReporter.quietPeriod, execute: work)
        }
    }

    /// Runs on the serial queue, so at most one dialog is ever on screen and a
    /// second burst simply waits behind the first.
    private func flush() {
        guard !pending.isEmpty else { return }
        let names = pending
        pending = []
        Log.info("unresolved dialog: \(names.joined(separator: ", "))")
        present(names)
    }

    // MARK: - Where to look

    private struct Resource {
        let label: String
        /// nil means "this option doesn't open a URL" (the clipboard entry).
        let url: ((String) -> String)?
    }

    private static let resources: [Resource] = [
        Resource(label: "Adobe Fonts — included with a Creative Cloud plan") {
            "https://fonts.adobe.com/search?query=\(encode($0))"
        },
        Resource(label: "Search the web") {
            "https://www.google.com/search?q=\(encode("\"\($0)\" font"))"
        },
        Resource(label: "MyFonts — commercial licensing") {
            "https://www.myfonts.com/search/\(encode($0))/"
        },
        Resource(label: "Fontspring — commercial licensing") {
            "https://www.fontspring.com/search?q=\(encode($0))"
        },
        Resource(label: "WhatTheFont — identify a font from a picture") { _ in
            "https://www.myfonts.com/pages/whatthefont"
        },
        Resource(label: "Copy the name to the clipboard", url: nil),
    ]

    private func present(_ names: [String]) {
        let primary = names[0]
        let list = names.map { "  •  \($0)" }.joined(separator: "\n")

        var explanation = """
        \(names.count == 1 ? "Couldn't find this font:" : "Couldn't find these \(names.count) fonts:")

        \(list)

        untofu searched the Google Fonts catalogue and found nothing that \
        answers to \(names.count == 1 ? "that name" : "those names"). That \
        usually means \(names.count == 1 ? "it's a commercial or private font" : "they're commercial or private fonts") \
        rather than an openly-licensed one.

        Your document has already substituted a fallback. Track the font down and \
        install it the normal way, and it will resolve from then on.
        """

        if names.count > 1 {
            explanation += "\n\nThe searches below look for \(primary); "
                         + "the clipboard option copies all \(names.count)."
        }
        explanation += "\n\nWhere would you like to look?"

        let options = UnresolvedReporter.resources
            .map { "\"\(Shell.escape($0.label))\"" }
            .joined(separator: ", ")

        let script = """
        set chosen to choose from list {\(options)} \
        with title "untofu" with prompt "\(Shell.escape(explanation))" \
        OK button name "Open" cancel button name "Dismiss"
        if chosen is false then
        return "@@dismissed@@"
        else
        return item 1 of chosen as text
        end if
        """

        let result = Shell.osascript(script)
        guard result.status == 0 else {
            Log.debug("could not present unresolved dialog: \(result.output)")
            return
        }
        guard result.output != "@@dismissed@@", !result.output.isEmpty else { return }

        guard let resource = UnresolvedReporter.resources.first(where: { $0.label == result.output })
        else { return }

        if let makeURL = resource.url {
            Shell.run("/usr/bin/open", [makeURL(primary)])
        } else {
            Shell.osascript("set the clipboard to \"\(Shell.escape(names.joined(separator: "\n")))\"")
        }
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
