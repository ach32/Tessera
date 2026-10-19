import Foundation

public struct FilterError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}

/// What a filter needs to know about the folders above a file. Computed once per directory.
public struct FolderContext {
    /// No folder include masks, or an ancestor matched one.
    public var included: Bool
    /// An ancestor matched a folder exclude mask.
    public var excluded: Bool
    /// Tags inherited from the ancestors.
    public var tagBits: UInt8

    public init(included: Bool, excluded: Bool, tagBits: UInt8) {
        self.included = included
        self.excluded = excluded
        self.tagBits = tagBits
    }
}

/// The filter language:
///   *.jpg  |*.jpg  \temp  |\temp  >100kb  disksize<1gb  size>10 mb  >1year  a>6months
///   :red  :a  |:g  :tag:red+green-b  :attr:hidden-locked  :class:Images
/// Conditions are separated by ";". Masks, tags and classes are OR-ed; exclusions and
/// everything else are AND-ed.
public final class CompiledFilter {
    public let source: String
    public let now: Double

    struct TagSpec { var any = false; var plus: UInt8 = 0; var minus: UInt8 = 0; var none = false }
    struct AttrSpec { var plus: FileAttributes = []; var minus: FileAttributes = [] }
    enum Compare { case lt, le, gt, ge }
    enum DateField { case created, modified, accessed }
    struct SizeCond { var metric: SizeMetric; var op: Compare; var bytes: Double; var negated: Bool }
    struct AgeCond { var field: DateField; var op: Compare; var seconds: Double; var negated: Bool }

    var includeNames: [Glob] = []
    var excludeNames: [Glob] = []
    var includeFolders: [Glob] = []
    var excludeFolders: [Glob] = []
    var includeTags: [TagSpec] = []
    var excludeTags: [TagSpec] = []
    var includeClasses: [Set<String>] = []
    var excludeClasses: [Set<String>] = []
    var attrConds: [(AttrSpec, Bool)] = []
    var sizeConds: [SizeCond] = []
    var ageConds: [AgeCond] = []

    init(source: String, now: Double) {
        self.source = source
        self.now = now
    }

    public var usesTags: Bool { !includeTags.isEmpty || !excludeTags.isEmpty }
    public var hasFolderMasks: Bool { !includeFolders.isEmpty || !excludeFolders.isEmpty }

    /// Folder-mask state for the children of `dir`, walking up from it (the scan root's
    /// own name, a full path, is not matched).
    public func context(for dir: FileNode) -> FolderContext {
        var included = includeFolders.isEmpty
        var excluded = false
        var bits: UInt8 = 0
        var n: FileNode? = dir
        while let c = n {
            bits |= c.tag.bit
            if c.parent != nil && c.isContainer {
                if !included && includeFolders.contains(where: { $0.matches(c.name) }) { included = true }
                if !excluded && excludeFolders.contains(where: { $0.matches(c.name) }) { excluded = true }
            }
            n = c.parent
        }
        return FolderContext(included: included, excluded: excluded, tagBits: bits)
    }

    /// True when a folder's name is one the include folder masks look for (drawn bold).
    public func highlightsFolder(_ name: String) -> Bool {
        includeFolders.contains { $0.matches(name) }
    }

    public func matches(_ file: FileNode, in ctx: FolderContext) -> Bool {
        guard file.isFile else { return false }
        if !ctx.included || ctx.excluded { return false }
        let tags = ctx.tagBits | file.tag.bit
        let ext = (includeClasses.isEmpty && excludeClasses.isEmpty) ? "" : file.fileExtension

        // OR group: names, tags, classes
        if !includeNames.isEmpty || !includeTags.isEmpty || !includeClasses.isEmpty {
            var hit = false
            if includeNames.contains(where: { $0.matches(file.name) }) { hit = true }
            if !hit && includeTags.contains(where: { CompiledFilter.tagMatch($0, tags) }) { hit = true }
            if !hit && includeClasses.contains(where: { $0.contains(ext) }) { hit = true }
            if !hit { return false }
        }
        // AND group: exclusions
        if excludeNames.contains(where: { $0.matches(file.name) }) { return false }
        if excludeTags.contains(where: { CompiledFilter.tagMatch($0, tags) }) { return false }
        if excludeClasses.contains(where: { $0.contains(ext) }) { return false }

        for (spec, negated) in attrConds {
            var ok = spec.plus.isEmpty || !file.attributes.isDisjoint(with: spec.plus)
            if ok && !spec.minus.isEmpty && !file.attributes.isDisjoint(with: spec.minus) { ok = false }
            if ok == negated { return false }
        }
        for c in sizeConds {
            let v = Double(file.size(c.metric))
            if CompiledFilter.compare(v, c.op, c.bytes) == c.negated { return false }
        }
        for c in ageConds {
            let date: Double
            switch c.field {
            case .created: date = file.created
            case .modified: date = file.modified
            case .accessed: date = file.accessed
            }
            let age = now - date
            if CompiledFilter.compare(age, c.op, c.seconds) == c.negated { return false }
        }
        return true
    }

    static func tagMatch(_ s: TagSpec, _ bits: UInt8) -> Bool {
        if s.none { return bits == 0 }
        var ok: Bool
        if s.any { ok = bits != 0 }
        else if s.plus != 0 { ok = bits & s.plus != 0 }
        else { ok = true }
        if ok && s.minus != 0 && bits & s.minus != 0 { ok = false }
        return ok
    }

    static func compare(_ a: Double, _ op: Compare, _ b: Double) -> Bool {
        switch op {
        case .lt: return a < b
        case .le: return a <= b
        case .gt: return a > b
        case .ge: return a >= b
        }
    }
}

public enum FilterParser {
    /// Returns nil for an empty filter.
    public static func parse(_ text: String,
                             classes: [FileClass] = FileClass.defaults,
                             decimalUnits: Bool = false,
                             now: Double = Date().timeIntervalSince1970) throws -> CompiledFilter? {
        let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let f = CompiledFilter(source: text, now: now)
        for part in parts {
            try parseCondition(part, into: f, classes: classes, decimal: decimalUnits)
        }
        return f
    }

    static func parseCondition(_ raw: String, into f: CompiledFilter, classes: [FileClass], decimal: Bool) throws {
        var s = Substring(raw)
        var negated = false
        if s.hasPrefix("|") {
            negated = true
            s = s.dropFirst()
            s = Substring(s.trimmingCharacters(in: .whitespaces))
        }
        guard !s.isEmpty else { throw FilterError(message: tr("“\(raw)” is missing what to exclude.", "В «\(raw)» не указано, что исключить.")) }

        if s.hasPrefix(":") {
            try parseColon(String(s.dropFirst()), negated: negated, raw: raw, into: f, classes: classes)
            return
        }
        if s.hasPrefix("\\") || s.hasPrefix("/") {
            let mask = String(s.dropFirst())
            guard !mask.isEmpty else { throw FilterError(message: tr("“\(raw)” needs a folder name after the \\.", "В «\(raw)» после \\ нужно имя папки.")) }
            if negated { f.excludeFolders.append(Glob(mask)) } else { f.includeFolders.append(Glob(mask)) }
            return
        }
        if let cmp = try parseComparison(String(s), raw: raw, negated: negated, decimal: decimal) {
            switch cmp {
            case .size(let c): f.sizeConds.append(c)
            case .age(let c): f.ageConds.append(c)
            }
            return
        }
        if negated { f.excludeNames.append(Glob(String(s))) } else { f.includeNames.append(Glob(String(s))) }
    }

    // MARK: :tag: :attr: :class: and the short tag form

    static func parseColon(_ body: String, negated: Bool, raw: String, into f: CompiledFilter, classes: [FileClass]) throws {
        enum Kind { case tag, attr, cls }
        var kind = Kind.tag
        var rest = body
        if let colon = body.firstIndex(of: ":") {
            let word = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
            let table: [(String, Kind)] = [("tags", .tag), ("tag", .tag), ("attributes", .attr), ("attrs", .attr), ("attr", .attr), ("class", .cls), ("classes", .cls)]
            let picked: Kind? = Fuzzy.pick(word, table)
            guard let k = picked else { throw FilterError(message: tr("Unknown filter type “:\(word):”. Use :tag:, :attr: or :class:.", "Неизвестный тип фильтра «:\(word):». Используйте :tag:, :attr: или :class:.")) }
            kind = k
            rest = String(body[body.index(after: colon)...])
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .tag:
            let spec = try parseTags(rest, raw: raw)
            if negated { f.excludeTags.append(spec) } else { f.includeTags.append(spec) }
        case .attr:
            let spec = try parseAttrs(rest, raw: raw)
            f.attrConds.append((spec, negated))
        case .cls:
            let want = rest.lowercased()
            guard !want.isEmpty else { throw FilterError(message: tr("“\(raw)” needs a class name.", "В «\(raw)» нужно имя вида файлов.")) }
            let found = classes.first(where: { $0.name.lowercased() == want })
                ?? classes.first(where: { $0.name.lowercased().hasPrefix(want) })
            guard let cls = found else {
                throw FilterError(message: tr("No file class named “\(rest)”. Classes: \(classes.map(\.name).joined(separator: ", ")).", "Нет вида файлов «\(rest)». Есть: \(classes.map(\.name).joined(separator: ", "))."))
            }
            let set = Set(cls.extensions.filter { !$0.isEmpty })
            if negated { f.excludeClasses.append(set) } else { f.includeClasses.append(set) }
        }
    }

    /// Splits "red+green-b" or "1,3,-red" into (word, isMinus) items.
    static func items(_ text: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        var cur = ""
        var minus = false
        func flush() {
            let w = cur.trimmingCharacters(in: .whitespaces)
            if !w.isEmpty { out.append((w.lowercased(), minus)) }
            cur = ""
        }
        for ch in text {
            switch ch {
            case "+", ",", " ": flush(); minus = false
            case "-": flush(); minus = true
            default: cur.append(ch)
            }
        }
        flush()
        return out
    }

    static func parseTags(_ text: String, raw: String) throws -> CompiledFilter.TagSpec {
        var spec = CompiledFilter.TagSpec()
        let list = items(text)
        guard !list.isEmpty else { throw FilterError(message: tr("“\(raw)” needs a tag: red, yellow, green, blue or all.", "В «\(raw)» нужен тег: red, yellow, green, blue или all.")) }
        for (word, minus) in list {
            if ["a", "al", "all", "any"].contains(word) {
                if minus { throw FilterError(message: tr("“-all” makes no sense in “\(raw)”.", "«-all» не имеет смысла в «\(raw)».")) }
                spec.any = true
                continue
            }
            if ["0", "none", "no", "n"].contains(word) { spec.none = true; continue }
            let tag: Tag? = {
                switch word {
                case "1": return .red
                case "2": return .yellow
                case "3": return .green
                case "4": return .blue
                default:
                    let table: [(String, Tag)] = [("red", .red), ("yellow", .yellow), ("green", .green), ("blue", .blue)]
                    return Fuzzy.pick(word, table)
                }
            }()
            guard let t = tag else { throw FilterError(message: tr("Unknown tag “\(word)” in “\(raw)”. Use red, yellow, green, blue (or 1–4).", "Неизвестный тег «\(word)» в «\(raw)». Используйте red, yellow, green, blue (или 1–4).")) }
            if minus { spec.minus |= t.bit } else { spec.plus |= t.bit }
        }
        return spec
    }

    static let attrNames: [(String, FileAttributes)] = [
        ("hidden", .hidden), ("hid", .hidden), ("h", .hidden),
        ("locked", .locked), ("readonly", .locked), ("ro", .locked), ("lock", .locked), ("l", .locked), ("r", .locked),
        ("compressed", .compressed), ("compr", .compressed), ("c", .compressed),
        ("system", .restricted), ("restricted", .restricted), ("sys", .restricted), ("s", .restricted),
        ("cloud", .dataless), ("dataless", .dataless), ("icloud", .dataless), ("d", .dataless),
        ("hardlink", .hardLink), ("hl", .hardLink), ("link", .hardLink),
        ("symlink", .symlink), ("alias", .symlink), ("sl", .symlink),
        ("executable", .executable), ("exec", .executable), ("exe", .executable), ("x", .executable),
        ("purgeable", .purgeable), ("purge", .purgeable), ("p", .purgeable),
        ("clone", .clone), ("cl", .clone),
    ]

    static func parseAttrs(_ text: String, raw: String) throws -> CompiledFilter.AttrSpec {
        var spec = CompiledFilter.AttrSpec()
        let list = items(text)
        guard !list.isEmpty else { throw FilterError(message: tr("“\(raw)” needs an attribute, for example hidden, locked, compressed.", "В «\(raw)» нужен атрибут, например hidden, locked, compressed.")) }
        for (word, minus) in list {
            guard let a = Fuzzy.pick(word, attrNames) else {
                throw FilterError(message: tr("Unknown attribute “\(word)”. Use hidden, locked, compressed, system, cloud, hardlink, symlink or executable.", "Неизвестный атрибут «\(word)». Используйте hidden, locked, compressed, system, cloud, hardlink, symlink или executable."))
            }
            if minus { spec.minus.formUnion(a) } else { spec.plus.formUnion(a) }
        }
        return spec
    }

    // MARK: size and age

    enum Comparison { case size(CompiledFilter.SizeCond), age(CompiledFilter.AgeCond) }

    static let sizeKeywords: [(String, SizeMetric)] = [
        ("disksize", .disk), ("disk", .disk), ("clustersize", .disk), ("cluster", .disk), ("ondisk", .disk),
        ("size", .logical), ("filesize", .logical), ("logicalsize", .logical), ("logical", .logical), ("file", .logical),
    ]
    static let ageKeywords: [(String, CompiledFilter.DateField)] = [
        ("modified", .modified), ("modify", .modified), ("modification", .modified), ("mod", .modified), ("changed", .modified),
        ("created", .created), ("creation", .created), ("create", .created), ("birth", .created), ("added", .created),
        ("accessed", .accessed), ("access", .accessed), ("opened", .accessed), ("used", .accessed),
    ]
    static let sizeUnits: [(String, Double)] = [
        ("b", 0), ("byte", 0), ("bytes", 0),
        ("k", 1), ("kb", 1), ("kib", 1),
        ("mb", 2), ("mib", 2),
        ("g", 3), ("gb", 3), ("gib", 3),
        ("t", 4), ("tb", 4), ("tib", 4),
    ]
    static let ageUnits: [(String, Double)] = [
        ("s", 1), ("sec", 1), ("secs", 1), ("second", 1), ("seconds", 1),
        ("m", 60), ("min", 60), ("mins", 60), ("minute", 60), ("minutes", 60),
        ("h", 3600), ("hr", 3600), ("hrs", 3600), ("hour", 3600), ("hours", 3600),
        ("d", 86400), ("day", 86400), ("days", 86400),
        ("w", 604_800), ("wk", 604_800), ("week", 604_800), ("weeks", 604_800),
        ("mo", 2_629_800), ("mon", 2_629_800), ("month", 2_629_800), ("months", 2_629_800),
        ("y", 31_557_600), ("yr", 31_557_600), ("yrs", 31_557_600), ("year", 31_557_600), ("years", 31_557_600),
    ]

    /// Returns nil when the text is not a comparison at all (so it is a name mask).
    static func parseComparison(_ text: String, raw: String, negated: Bool, decimal: Bool) throws -> Comparison? {
        let s = text.lowercased().filter { !$0.isWhitespace }
        guard let opIndex = s.firstIndex(where: { $0 == "<" || $0 == ">" }) else { return nil }
        let keyword = String(s[..<opIndex])
        guard keyword.allSatisfy({ $0.isLetter }) else { return nil }
        var i = s.index(after: opIndex)
        var op: CompiledFilter.Compare = s[opIndex] == "<" ? .lt : .gt
        if i < s.endIndex && s[i] == "=" {
            op = op == .lt ? .le : .ge
            i = s.index(after: i)
        }
        let numStart = i
        while i < s.endIndex && (s[i].isNumber || s[i] == "." || s[i] == ",") { i = s.index(after: i) }
        let numText = s[numStart..<i].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numText) else {
            throw FilterError(message: tr("“\(raw)” needs a number after \(op == .lt || op == .le ? "<" : ">").", "В «\(raw)» после \(op == .lt || op == .le ? "<" : ">") нужно число."))
        }
        let unit = String(s[i...])

        let sizeUnit = sizeUnits.first(where: { $0.0 == unit })?.1
        let ageUnit = ageUnits.first(where: { $0.0 == unit })?.1
        let sizeKw: SizeMetric? = keyword.isEmpty ? nil : Fuzzy.pick(keyword, sizeKeywords)
        let ageKw: CompiledFilter.DateField? = keyword.isEmpty ? nil : Fuzzy.pick(keyword, ageKeywords)

        if !keyword.isEmpty && sizeKw == nil && ageKw == nil {
            throw FilterError(message: tr("Unknown keyword “\(keyword)” in “\(raw)”. Use disksize, size, modified, created or accessed.", "Неизвестное слово «\(keyword)» в «\(raw)». Используйте disksize, size, modified, created или accessed."))
        }
        let base = decimal ? 1000.0 : 1024.0

        // Decide size vs age: the unit wins, then the keyword.
        let isSize: Bool
        if sizeUnit != nil && ageUnit == nil { isSize = true }
        else if ageUnit != nil && sizeUnit == nil { isSize = false }
        else if unit.isEmpty { isSize = ageKw == nil }
        else { throw FilterError(message: tr("Unknown unit “\(unit)” in “\(raw)”. Sizes: b, kb, mb, gb, tb. Ages: s, min, h, d, w, months, y.", "Неизвестная единица «\(unit)» в «\(raw)». Размер: b, kb, mb, gb, tb. Возраст: s, min, h, d, w, months, y.")) }

        if isSize {
            if ageKw != nil && sizeKw == nil {
                throw FilterError(message: tr("“\(raw)” compares a date with a size unit.", "«\(raw)» сравнивает дату с единицей размера."))
            }
            let bytes = value * pow(base, sizeUnit ?? 0)
            return .size(.init(metric: sizeKw ?? .disk, op: op, bytes: bytes, negated: negated))
        } else {
            if sizeKw != nil && ageKw == nil {
                throw FilterError(message: tr("“\(raw)” compares a size with an age unit.", "«\(raw)» сравнивает размер с единицей времени."))
            }
            return .age(.init(field: ageKw ?? .modified, op: op, seconds: value * (ageUnit ?? 1), negated: negated))
        }
    }
}
