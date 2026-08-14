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

    func answers(to psName: String) -> Bool {
        let wanted = psName.lowercased()
        return postScriptNames.contains { $0.lowercased() == wanted }
    }

    static func read(_ url: URL) -> FontFile? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let r = Reader(data)
        var collected = Set<String>()
        for offset in sfntOffsets(r) {
            collected.formUnion(psNames(in: r, at: offset))
        }
        return collected.isEmpty ? nil : FontFile(url: url, postScriptNames: collected)
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

    private static func psNames(in r: Reader, at base: Int) -> Set<String> {
        guard let tableCount = r.u16(base + 4) else { return [] }
        var nameTable: Int?
        var fvarTable: Int?
        for i in 0..<Int(tableCount) {
            let rec = base + 12 + 16 * i
            guard let tag = r.u32(rec), let off = r.u32(rec + 8) else { continue }
            if tag == 0x6E61_6D65 { nameTable = Int(off) }   // 'name'
            if tag == 0x6676_6172 { fvarTable = Int(off) }   // 'fvar'
        }
        guard let nameOffset = nameTable else { return [] }
        let records = nameRecords(r, at: nameOffset)

        var result = Set<String>()
        if let own = records[6] { result.insert(own) }       // nameID 6 = PostScript name
        if let fvarOffset = fvarTable {
            result.formUnion(instanceNames(r, at: fvarOffset, names: records))
        }
        return result
    }

    /// nameID -> string, preferring the Windows/Unicode record when a nameID
    /// appears on several platforms.
    private static func nameRecords(_ r: Reader, at base: Int) -> [UInt16: String] {
        guard let count = r.u16(base + 2), let storage = r.u16(base + 4) else { return [:] }
        var out: [UInt16: String] = [:]
        for i in 0..<Int(count) {
            let rec = base + 6 + 12 * i
            guard let platform = r.u16(rec),
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
            if out[nameID] == nil || platform == 3 { out[nameID] = value }
        }
        return out
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
