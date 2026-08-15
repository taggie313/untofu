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
    /// Matching is on the exact family slug, so Google families with overlapping
    /// words are unaffected — `librebaskerville` does not match `baskerville`.
    private static let proprietarySlugs: Set<String> = [
        // Microsoft Office core and ClearType
        "calibri", "cambria", "candara", "consolas", "constantia", "corbel",
        "aptos", "segoeui", "segoe", "sitka", "bierstadt", "grandview",
        "seaford", "skeena", "tenorite", "marlett", "msreferencesansserif",
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
    static func isKnownProprietary(_ psName: String) -> Bool {
        familyCandidates(for: psName).contains { proprietarySlugs.contains($0) }
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
