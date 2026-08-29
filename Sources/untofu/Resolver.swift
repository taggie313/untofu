import Foundation

/// Turns a PostScript name into the family slugs worth trying.
///
/// PostScript names are conventionally `Family-Style`, but the family half often
/// carries a grouping token that is not part of the real family name. Raleway is
/// the motivating case: `RalewayRoman-Regular` lives under `ofl/raleway`, not
/// `ofl/ralewayroman`. Candidates come back most-likely first; a wrong guess
/// costs one 404 and is caught anyway by the PostScript-name verification that
/// runs before anything is cached.
enum Resolver {
    /// Tokens that group a family into roman/italic halves rather than naming it.
    private static let groupingSuffixes = ["Roman", "Italic", "Upright"]

    static func familyCandidates(for psName: String) -> [String] {
        let trimmed = psName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Everything before the first hyphen is the family; the rest is style.
        let family = trimmed.split(separator: "-", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? trimmed

        var candidates: [String] = []
        for suffix in groupingSuffixes where family.hasSuffix(suffix) && family.count > suffix.count {
            candidates.append(String(family.dropLast(suffix.count)))
        }
        candidates.append(family)

        var seen = Set<String>()
        return candidates.map(slug).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Google's font directories are lowercase and stripped of punctuation:
    /// "Playfair Display" -> `playfairdisplay`.
    static func slug(_ family: String) -> String {
        family.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Families that will never be on Google Fonts and are requested constantly.
    ///
    /// Opening any PowerPoint file asks for Calibri, Aptos and Segoe UI; opening a
    /// PDF asks for the base-14 names. Without this, every Office document would
    /// pop a "couldn't find 5 fonts" dialog listing fonts the user can do nothing
    /// about, and burn three GitHub API calls per name confirming it.
    ///
    /// Matching is anchored at the start and runs in whole words, so Google
    /// families with overlapping words are unaffected: `librebaskerville` does
    /// not match `baskerville`, and `courierprime` is not `courier`.
    private static let proprietarySlugs: Set<String> = [
        // Microsoft Office core and ClearType
        "calibri", "cambria", "candara", "consolas", "constantia", "corbel",
        "aptos", "segoeui", "segoe", "sitka", "bierstadt", "grandview",
        "seaford", "skeena", "tenorite", "marlett", "msreferencesansserif",
        // Sub-families common enough to be worth naming outright, so a cold
        // install with no catalogue yet still suppresses the ones a single
        // PowerPoint deck asks for.
        "aptosdisplay", "aptosnarrow", "aptosserif", "aptosmono", "aptosslab",
        "segoeuisemibold", "segoeuilight", "segoeuiemoji", "segoeuisymbol",
        "cambriamath", "arialunicodems", "arialroundedmtbold",
        // Classic Microsoft web-core
        "arial", "arialblack", "arialnarrow", "timesnewroman", "couriernew",
        "georgia", "verdana", "tahoma", "trebuchetms", "comicsansms", "impact",
        "webdings", "wingdings", "wingdings2", "wingdings3", "symbol",
        "msgothic", "msmincho", "simsun", "malgungothic",
        // Apple system faces
        "helvetica", "helveticaneue", "sfpro", "sfprotext", "sfprodisplay",
        "sfmono", "sfnsdisplay", "sfnstext", "geneva", "monaco", "menlo",
        "lucidagrande", "avenir", "avenirnext", "optima", "palatino",
        "baskerville", "futura", "gillsans", "hoeflertext", "zapfino",
        "chalkboard", "chalkboardse", "papyrus", "skia", "charter", "seravek",
        "superclarendon", "americantypewriter", "markerfelt", "noteworthy",
        "snellroundhand", "applesdgothicneo", "hiraginosans", "pingfangsc",
        // PDF base-14 and common Adobe originals
        "times", "courier", "zapfdingbats", "myriad", "myriadpro", "minion",
        "minionpro", "adobegaramond", "trajan", "trajanpro", "warnock",
        "chaparral", "cronos", "tekton", "birch", "blackoak", "poplar",
    ]

    /// True when the name belongs to a family we know we cannot fetch, so the
    /// lookup can be skipped entirely and the user left unbothered.
    ///
    /// Matching the whole slug is not enough, and the gap was not academic:
    /// opening a PowerPoint deck asks for both `Aptos` and `Aptos Display`. The
    /// first matched `aptos` and was silently dropped as intended; the second
    /// slugged to `aptosdisplay`, missed the set, burned a round of GitHub
    /// lookups and popped a dialog telling the user to go buy a font — one of a
    /// dozen sub-families (`Aptos Narrow/Serif/Mono/Slab`, `Segoe UI Semibold`,
    /// `Cambria Math`, `Arial Unicode MS`) that all escaped the same way.
    ///
    /// So a *leading run of whole words* counts too. Words, not characters:
    /// "Courier Prime" is a real Google family and must not be suppressed by
    /// "courier", but a bare `hasPrefix` on the squashed slug would do exactly
    /// that. As a second guard the catalogue gets a veto — if google/fonts
    /// actually ships this family, it is fetchable whatever its first word says.
    static func isKnownProprietary(_ psName: String) -> Bool {
        if familyCandidates(for: psName).contains(where: { proprietarySlugs.contains($0) }) {
            return true
        }

        let words = familyWords(for: psName)
        guard words.count > 1 else { return false }

        // Longest first, so "segoe ui" is preferred over "segoe" — they are both
        // in the set and the longer match is the more specific statement.
        for length in stride(from: words.count - 1, through: 1, by: -1) {
            guard proprietarySlugs.contains(words.prefix(length).joined()) else { continue }

            // The veto only means anything if we can actually consult the
            // catalogue. Suppressing on a guess is the worse failure of the two:
            // a wrong dialog is noise, but a wrong suppression silently disables
            // the one thing this tool exists to do. So with no catalogue on disk
            // the word rule stands down and behaviour falls back to the exact
            // match — which is what shipped before this rule existed.
            guard let catalogue = GoogleFonts.cachedFamilySlugs() else {
                Log.debug("no catalogue on disk; not judging \(psName) by its first word")
                return false
            }
            if catalogue.contains(words.joined()) {
                Log.debug("\(psName) starts with a proprietary family but "
                        + "\(words.joined()) is in the catalogue — not suppressing")
                return false
            }
            return true
        }
        return false
    }

    /// The family half, split into lowercased words.
    ///
    /// Both spellings a font request arrives in have to land on the same answer:
    /// applications ask for the spaced display form ("Aptos Display") about as
    /// often as the PostScript form ("AptosDisplay-Bold"), so camel humps are
    /// word boundaries alongside spaces and punctuation.
    static func familyWords(for psName: String) -> [String] {
        let trimmed = psName.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = trimmed.split(separator: "-", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? trimmed

        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in family {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                previous = nil
                continue
            }
            // "MT" then "Bold" must not fuse: break on the hump *before* the last
            // capital of a run, not only on lower-to-upper.
            if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current.lowercased()) }

        // A grouping token names no family of its own — drop it so
        // "RalewayRoman" is one word, "raleway", exactly as the slug is.
        if let last = words.last, words.count > 1,
           groupingSuffixes.contains(where: { $0.lowercased() == last }) {
            words.removeLast()
        }
        return words
    }

    /// Human-readable family for notifications: `PlayfairDisplay-Bold` reads far
    /// better as "Playfair Display" than as its PostScript spelling.
    static func displayFamily(for psName: String) -> String {
        let family = psName.split(separator: "-", maxSplits: 1,
                                  omittingEmptySubsequences: false).first.map(String.init) ?? psName
        var base = family
        for suffix in groupingSuffixes where base.hasSuffix(suffix) && base.count > suffix.count {
            base = String(base.dropLast(suffix.count))
            break
        }

        var spaced = ""
        var previous: Character?
        for character in base {
            if let previous, previous.isLowercase, character.isUppercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced
    }
}
