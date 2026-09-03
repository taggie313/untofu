import Foundation

/// Every PostScript name a font file can answer to.
///
/// This is the verification step that keeps a wrong download out of the cache,
/// and it matters more than it looks. Google's Raleway answers to
/// `RalewayRoman-Regular` — a name that exists only as a variable-font *named
/// instance*, not as the file's own `name` table entry, which reads
/// `Raleway-Thin`. Other builds of the same family answer to `Raleway-Regular`
/// instead. Matching on family name alone caches a file that will never satisfy
/// the request, and the failure is silent.
struct FontFile {
    let url: URL
    let postScriptNames: Set<String>

    /// The subset that identifies one specific face rather than a whole family.
    ///
    /// Every face in a family carries the family name in its `name` table, so
    /// `postScriptNames` for Calibri Italic contains "Calibri" just as Calibri
    /// Regular's does. That is correct for answering "could this file satisfy the
    /// request" — a bare family request is satisfiable by any member — but it is
    /// useless for choosing *between* candidates, and choosing badly is visible:
    /// a request for Calibri answered with Calibrii.ttf renders the document in
    /// italic. These names are the ones that pick a face unambiguously.
    let exactNames: Set<String>

    /// Style within the family — "Regular", "Bold Italic", "Light" — from the
    /// typographic subfamily where the font has one, else the legacy field.
    let subfamily: String?

    /// OS/2 usWeightClass: 400 is regular, 700 bold, 300 light. Nil when the
    /// font has no OS/2 table, which is rare outside bitmap and CJK legacy faces.
    let weightClass: Int?

    /// Whether OS/2 flags this face as italic or oblique.
    let isItalic: Bool

    func answers(to psName: String) -> Bool {
        let wanted = psName.lowercased()
        return postScriptNames.contains { $0.lowercased() == wanted }
    }

    /// How plain this face is, 0–100. Used to break a tie between files that all
    /// answer to the same bare family name: absent any other information, the
    /// regular upright weight is what an application asking for "Calibri" wants.
    ///
    /// Scored on the weight axis rather than by counting style words, because
    /// the interesting case is a family where no regular exists at all. An Adobe
    /// Fonts library with Myriad Pro activated in Light, SemiBold and Bold has
    /// three faces a request for "Myriad Pro" could be answered with, and they
    /// are equally many words. Light is a far better answer than Bold, and only
    /// the weight axis says so.
    var plainness: Int {
        if let weightClass {
            // 400 is regular; every 10 points away costs 1, so 300 (Light)
            // outranks 600 (SemiBold) outranks 700 (Bold).
            let distance = abs(weightClass - 400) / 10
            return max(0, 100 - distance) - (isItalic ? 30 : 0)
        }
        guard let subfamily = subfamily?.lowercased() else { return 0 }
        if subfamily == "regular" || subfamily == "book" { return 100 }
        let words = subfamily.split(whereSeparator: { !$0.isLetter }).count
        return max(0, 50 - 10 * words) - (isItalic ? 30 : 0)
    }

    static func read(_ url: URL) -> FontFile? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let r = Reader(data)
        var all = Set<String>()
        var exact = Set<String>()
        var subfamily: String?
        var weightClass: Int?
        var isItalic = false
        for offset in sfntOffsets(r) {
            let parsed = psNames(in: r, at: offset)
            all.formUnion(parsed.all)
            exact.formUnion(parsed.exact)
            // A .ttc holds several faces; the first is as good a label as any and
            // plainness only ever breaks ties between whole files.
            if subfamily == nil { subfamily = parsed.subfamily }
            if weightClass == nil {
                let metrics = os2Metrics(r, at: offset)
                weightClass = metrics.weightClass
                isItalic = metrics.isItalic
            }
        }
        return all.isEmpty ? nil : FontFile(url: url, postScriptNames: all,
                                            exactNames: exact, subfamily: subfamily,
                                            weightClass: weightClass, isItalic: isItalic)
    }

    /// usWeightClass and the italic flag out of the OS/2 table.
    private static func os2Metrics(_ r: Reader, at base: Int) -> (weightClass: Int?, isItalic: Bool) {
        guard let tableCount = r.u16(base + 4) else { return (nil, false) }
        var os2: Int?
        for i in 0..<Int(tableCount) {
            let rec = base + 12 + 16 * i
            guard let tag = r.u32(rec), let off = r.u32(rec + 8) else { continue }
            if tag == 0x4F53_2F32 { os2 = Int(off); break }   // 'OS/2'
        }
        guard let os2 else { return (nil, false) }
        let weight = r.u16(os2 + 4).map(Int.init)
        // fsSelection bit 0 is ITALIC. The field sits at offset 62, past the end
        // of a truncated table, so a nil read simply means "not flagged".
        let italic = (r.u16(os2 + 62).map { $0 & 0x01 != 0 }) ?? false
        // A nonsense weight is worse than none: some fonts write 0, and older
        // ones use the 1-9 scale rather than 100-900.
        guard let weight, weight >= 100, weight <= 1000 else { return (nil, italic) }
        return (weight, italic)
    }

    // MARK: - SFNT walking

    /// Font collections (.ttc) hold several fonts in one file; everything else is
    /// a single font at offset 0.
    private static func sfntOffsets(_ r: Reader) -> [Int] {
        guard let tag = r.u32(0) else { return [] }
        guard tag == 0x7474_6366 else { return [0] } // 'ttcf'
        guard let count = r.u32(8) else { return [] }
        return (0..<Int(count)).compactMap { r.u32(12 + 4 * $0).map(Int.init) }
    }

    private struct ParsedNames {
        var all: Set<String> = []
        var exact: Set<String> = []
        var subfamily: String?
    }

    private static func psNames(in r: Reader, at base: Int) -> ParsedNames {
        guard let tableCount = r.u16(base + 4) else { return ParsedNames() }
        var nameTable: Int?
        var fvarTable: Int?
        for i in 0..<Int(tableCount) {
            let rec = base + 12 + 16 * i
            guard let tag = r.u32(rec), let off = r.u32(rec + 8) else { continue }
            if tag == 0x6E61_6D65 { nameTable = Int(off) }   // 'name'
            if tag == 0x6676_6172 { fvarTable = Int(off) }   // 'fvar'
        }
        guard let nameOffset = nameTable else { return ParsedNames() }
        let records = nameRecords(r, at: nameOffset)

        var parsed = ParsedNames()
        parsed.subfamily = records.best[17] ?? records.best[2]   // typographic, then legacy
        if let own = records.best[6] { parsed.exact.insert(own) } // nameID 6 = PostScript name
        if let fvarOffset = fvarTable {
            // A named instance names one point in the design space, so it picks a
            // face as precisely as nameID 6 does.
            parsed.exact.formUnion(instanceNames(r, at: fvarOffset, names: records.best))
        }
        var result = parsed.exact

        // Family names too, spaced and squashed. Applications do not always ask
        // by PostScript name: PowerPoint requests a bare "Roboto" for a theme
        // font with no style, and matching only PostScript names rejects the very
        // file that satisfies it. Matching stays exact, so this cannot pull in an
        // unrelated family.
        //
        // EVERY spelling, not just the preferred one. Scoring above decides what
        // to *call* this face; it must not decide what the face can be *found*
        // by. A Chinese-locale application asks for 宋体 and an English one asks
        // for SimSun, and the file answers to both — so index both. Matching is
        // exact, so extra spellings can never pull in an unrelated family.
        var families = Set<String>()
        for nameID in [16, 1] as [UInt16] {                  // typographic, then legacy
            if let best = records.best[nameID] { families.insert(best) }
            families.formUnion(records.alternates[nameID] ?? [])
        }
        for family in families where !family.isEmpty {
            result.insert(family)
            result.insert(squashed(family))

            // "Inter Medium", the spaced display form. Applications ask this way
            // constantly — it is what a font menu shows — and untofu indexed only
            // "Inter-Medium" and bare "Inter". A real miss report arrived for
            // Inter, a font that was fetchable the whole time under a spelling
            // the requester did not use.
            if let style = parsed.subfamily, !style.isEmpty,
               style.lowercased() != "regular" {
                result.insert("\(family) \(style)")
                result.insert(squashed("\(family)\(style)"))
            }
        }
        parsed.all = result
        return parsed
    }

    /// Every spelling of every nameID, plus which one to prefer.
    struct NameTable {
        /// The best spelling per nameID — English where the font has one.
        var best: [UInt16: String] = [:]
        /// Every spelling seen, including localized ones.
        var alternates: [UInt16: Set<String>] = [:]
    }

    /// How much a `name` record is worth as *the* spelling of its nameID.
    ///
    /// This exists because "prefer platform 3" is not enough, and getting it
    /// wrong was quietly catastrophic. Records are laid out sorted by platform,
    /// encoding, language, nameID — so the English record (platform 3, langID
    /// 0x0409) comes first and any localized record for the same nameID comes
    /// later. "Last platform-3 record wins" therefore means "the localized name
    /// always wins", and every font shipping a localized name lost its English
    /// one before anything downstream could see it.
    ///
    /// Measured across the Office bundles and /System/Library/Fonts, 1574 faces:
    /// nameID 1 resolved to a non-English string on 319 of them. SimHei.ttf sat
    /// in the first directory untofu walks, indexed only as 黑体, so a document
    /// asking for "SimHei" missed, burned lookups, and was told it was a
    /// commercial font.
    private static func nameScore(platform: UInt16, language: UInt16) -> Int {
        switch (platform, language) {
        case (3, 0x0409): return 100   // Windows, US English
        case (1, 0):      return 90    // Macintosh, English
        case (0, _):      return 80    // Unicode, no language of its own
        case (3, _):      return 50    // Windows, localized
        case (1, _):      return 40    // Macintosh, localized
        default:          return 10
        }
    }

    private static func nameRecords(_ r: Reader, at base: Int) -> NameTable {
        guard let count = r.u16(base + 2), let storage = r.u16(base + 4) else { return NameTable() }
        var table = NameTable()
        var scores: [UInt16: Int] = [:]
        for i in 0..<Int(count) {
            let rec = base + 6 + 12 * i
            guard let platform = r.u16(rec),
                  let language = r.u16(rec + 4),
                  let nameID = r.u16(rec + 6),
                  let length = r.u16(rec + 8),
                  let offset = r.u16(rec + 10),
                  let raw = r.bytes(base + Int(storage) + Int(offset), Int(length))
            else { continue }

            let decoded: String?
            switch platform {
            case 1:  decoded = String(data: raw, encoding: .macOSRoman)
            default: decoded = String(data: raw, encoding: .utf16BigEndian)
            }
            guard let value = decoded, !value.isEmpty else { continue }

            table.alternates[nameID, default: []].insert(value)
            let score = nameScore(platform: platform, language: language)
            if score > (scores[nameID] ?? Int.min) {
                scores[nameID] = score
                table.best[nameID] = value
            }
        }
        return table
    }

    /// PostScript names of a variable font's named instances.
    private static func instanceNames(_ r: Reader, at base: Int,
                                      names: [UInt16: String]) -> Set<String> {
        guard let axesOffset = r.u16(base + 4),
              let axisCount = r.u16(base + 8),
              let axisSize = r.u16(base + 10),
              let instanceCount = r.u16(base + 12),
              let instanceSize = r.u16(base + 14)
        else { return [] }

        // postScriptNameID is an optional trailing field: present only when the
        // instance record is large enough to hold it. Reading it unconditionally
        // yields garbage name IDs on fonts that omit it.
        let coordsSize = Int(axisCount) * 4
        guard Int(instanceSize) >= coordsSize + 4 else { return [] }
        let hasExplicitPSNames = Int(instanceSize) >= coordsSize + 6

        // The typographic family is the right base for instance names. The legacy
        // family (nameID 1) is split per style on families like Raleway, whose
        // nameID 1 reads "Raleway Thin" rather than "Raleway".
        let family = names[16] ?? names[1]

        let start = base + Int(axesOffset) + Int(axisCount) * Int(axisSize)
        var out = Set<String>()
        for i in 0..<Int(instanceCount) {
            let rec = start + i * Int(instanceSize)

            if hasExplicitPSNames,
               let psNameID = r.u16(rec + 4 + coordsSize),
               let value = names[psNameID], !value.isEmpty {
                out.insert(value)
            }

            // Plenty of variable fonts omit postScriptNameID entirely — Lora does.
            // CoreText will still instantiate those weights happily from the
            // variable file, so index the conventional Family-Style spelling too.
            // Without this the verifier rejects a file that genuinely satisfies
            // the request, and a request for Lora-Bold fails even though handing
            // over Lora[wght].ttf demonstrably works.
            if let family,
               let subfamilyID = r.u16(rec),
               let style = names[subfamilyID], !style.isEmpty {
                out.insert("\(squashed(family))-\(squashed(style))")
                // And the spaced display form. A font menu shows "Inter Medium",
                // so that is what applications ask for; indexing only the
                // hyphenated spelling meant a fetchable font looked missing.
                out.insert("\(family) \(style)")
            }
        }
        return out
    }

    /// PostScript names carry no spaces: "Playfair Display" + "Extra Bold"
    /// conventionally spells PlayfairDisplay-ExtraBold.
    private static func squashed(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}

/// Bounds-checked big-endian reads. Font files are untrusted input; a truncated
/// or hostile file must yield nil rather than a crash.
private struct Reader {
    private let d: Data
    init(_ data: Data) { d = data }

    private func byte(_ o: Int) -> UInt8? {
        guard o >= 0, o < d.count else { return nil }
        return d[d.startIndex + o]
    }

    func u16(_ o: Int) -> UInt16? {
        guard let a = byte(o), let b = byte(o + 1) else { return nil }
        return UInt16(a) << 8 | UInt16(b)
    }

    func u32(_ o: Int) -> UInt32? {
        guard let a = byte(o), let b = byte(o + 1),
              let c = byte(o + 2), let e = byte(o + 3) else { return nil }
        return UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(e)
    }

    func bytes(_ o: Int, _ n: Int) -> Data? {
        guard o >= 0, n >= 0, o + n <= d.count else { return nil }
        return d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + n))
    }
}
