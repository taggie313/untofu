import CoreText
import Foundation

/// Reads a document and reports the fonts it references.
///
/// This exists to remove the worst moment in the product. A fetch is
/// asynchronous by design — the provider callback must return in microseconds or
/// it stalls the requesting app's text layout — so the document that triggers a
/// miss has already rendered with a substitute by the time the font arrives. The
/// first thing a new user sees is therefore "nothing happened". Scanning a file
/// ahead of opening it turns that first open into a cache hit.
enum Scanner {

    enum Format {
        case iWork      // .key .pages .numbers — zip of compressed protobuf
        case ooxml      // .pptx .docx .xlsx — zip of XML
        case pdf
        case unknown
    }

    /// Font names a document refers to, deduplicated, in encounter order.
    static func fonts(in url: URL) -> (format: Format, names: [String]) {
        let format = detect(url)
        let names: [String]
        switch format {
        case .iWork: names = iWorkFonts(url)
        case .ooxml: names = ooxmlFonts(url)
        case .pdf:   names = pdfFonts(url)
        case .unknown: names = []
        }
        var seen = Set<String>()
        return (format, names.filter { seen.insert($0.lowercased()).inserted })
    }

    /// By content, not by extension: a .key that is really a zip and a .pdf that
    /// is really a zip are both things that happen.
    private static func detect(_ url: URL) -> Format {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return .unknown }

        if magic.starts(with: Data("%PDF".utf8)) { return .pdf }
        guard magic.starts(with: Data([0x50, 0x4B])) else { return .unknown }   // "PK"

        let entries = Shell.run("/usr/bin/unzip", ["-Z1", url.path]).output
        if entries.contains(".iwa") { return .iWork }
        if entries.contains("[Content_Types].xml") { return .ooxml }
        return .unknown
    }

    // MARK: - Office

    /// Precise: OOXML names fonts in attributes.
    ///
    /// `+mj-lt` and friends are theme references rather than font names — the
    /// theme part they point at is picked up separately, since theme1.xml
    /// carries the real typeface.
    private static func ooxmlFonts(_ url: URL) -> [String] {
        let xml = Shell.runData("/usr/bin/unzip",
                                ["-p", url.path, "*.xml"]).utf8String
        let patterns = [#"typeface="([^"]+)""#,      // DrawingML (pptx, shared)
                        #"w:ascii="([^"]+)""#,       // WordprocessingML
                        #"val="([^"]+)"[^>]*/>\s*</rFont>"#]  // SpreadsheetML rFont
        return patterns.flatMap { matches(of: $0, in: xml) }
                       .filter { !$0.hasPrefix("+") && !$0.isEmpty }
    }

    // MARK: - PDF

    /// Precise: `/BaseFont /Name`.
    ///
    /// A six-letter `ABCDEF+` prefix marks a subset, which means the font is
    /// embedded in the file and will never be requested from the system — those
    /// are skipped rather than pointlessly fetched.
    private static func pdfFonts(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let text = data.utf8String
        return matches(of: #"/BaseFont\s*/([A-Za-z0-9+._-]+)"#, in: text)
            .filter { !$0.contains("+") }
            .map { $0.replacingOccurrences(of: "#20", with: " ") }
    }

    // MARK: - iWork

    /// Heuristic, unavoidably.
    ///
    /// iWork stores its document model as snappy-compressed protobuf in
    /// `Index/*.iwa`, with no schema shipped and no attribute to key on. Font
    /// names do survive as plain strings inside the compressed stream often
    /// enough to be useful, so this pulls printable runs and keeps the ones
    /// shaped like font names.
    ///
    /// False positives are cheap and self-correcting: anything that is not a
    /// real family fails verification in Fetcher, gets negative-cached, and is
    /// never retried. False negatives just mean the old behaviour — one missed
    /// first open.
    private static func iWorkFonts(_ url: URL) -> [String] {
        let raw = Shell.runData("/usr/bin/unzip", ["-p", url.path, "Index/*.iwa"])
        var out: [String] = []
        var current = [UInt8]()

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= 4, current.count <= 64,
                  let s = String(bytes: current, encoding: .utf8) else { return }
            if looksLikeFontName(s) { out.append(s) }
        }

        for byte in raw {
            // Printable ASCII, plus space and hyphen which font names contain.
            if byte >= 0x20 && byte < 0x7F { current.append(byte) } else { flush() }
        }
        flush()
        return out
    }

    /// Deliberately conservative. Every accepted candidate that is wrong costs a
    /// catalogue lookup, and the GitHub API allows 60 an hour unauthenticated.
    private static func looksLikeFontName(_ s: String) -> Bool {
        guard s.count >= 4, s.count <= 64 else { return false }
        guard let first = s.first, first.isLetter, first.isUppercase else { return false }
        guard s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }) else { return false }
        guard !s.hasSuffix(" "), !s.hasPrefix(" ") else { return false }
        // Prose sneaks through otherwise: real font names are not sentences.
        guard s.split(separator: " ").count <= 4 else { return false }
        // A lone dictionary word is far more likely to be document text than a
        // family, so require either a style suffix or internal capitalisation.
        if s.contains("-") { return true }
        return s.dropFirst().contains { $0.isUppercase }
    }

    // MARK: - Shared

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Whether the system can already satisfy this name without us.
    ///
    /// `preventAutoActivation` matters: without it this very lookup would go out
    /// to the running provider, which would treat it as a miss and start a fetch
    /// — so the check for "do we need to fetch?" would itself cause the fetch.
    static func isAlreadyAvailable(_ name: String) -> Bool {
        let font = CTFontCreateWithNameAndOptions(name as CFString, 12, nil, [.preventAutoActivation])
        let ps = CTFontCopyPostScriptName(font) as String
        let family = CTFontCopyFamilyName(font) as String
        return ps.caseInsensitiveCompare(name) == .orderedSame
            || family.caseInsensitiveCompare(name) == .orderedSame
    }
}

private extension Data {
    /// Font files and compressed streams are not valid UTF-8; decoding leniently
    /// is the point, since only the ASCII runs matter.
    var utf8String: String {
        String(decoding: self, as: UTF8.self)
    }
}
