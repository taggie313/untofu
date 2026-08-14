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
