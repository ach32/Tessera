import Foundation

public enum NodeKind: UInt8 {
    case volume = 0
    case folder = 1
    case file = 2
    case freeSpace = 3
    case unknownSpace = 4
    /// A directory on another device that the scan does not enter.
    case mountPoint = 5
    /// Space macOS frees by itself when needed (local snapshots, iCloud caches…).
    case purgeable = 6
}

public enum ScanState: UInt8 {
    case pending = 0
    case done = 1
    case denied = 2
}

public struct FileAttributes: OptionSet, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let hidden     = FileAttributes(rawValue: 1 << 0)
    public static let locked     = FileAttributes(rawValue: 1 << 1)
    public static let compressed = FileAttributes(rawValue: 1 << 2)
    public static let restricted = FileAttributes(rawValue: 1 << 3)
    public static let dataless   = FileAttributes(rawValue: 1 << 4)
    public static let hardLink   = FileAttributes(rawValue: 1 << 5)
    public static let symlink    = FileAttributes(rawValue: 1 << 6)
    public static let executable = FileAttributes(rawValue: 1 << 7)
    /// An APFS clone: shares blocks with another file (counted once).
    public static let clone      = FileAttributes(rawValue: 1 << 8)
    /// APFS marked the file purgeable: macOS may delete it by itself when space runs low.
    public static let purgeable  = FileAttributes(rawValue: 1 << 9)
}

/// Tag colours. Stored as 0 (none) ... 4 on the node, as a bit mask (1 << (tag-1)) in filters.
public enum Tag: UInt8, CaseIterable {
    case none = 0, red = 1, yellow = 2, green = 3, blue = 4

    public var bit: UInt8 { self == .none ? 0 : 1 << (rawValue - 1) }
    public var name: String {
        switch self {
        case .none: return tr("None", "Нет")
        case .red: return tr("Red", "Красный")
        case .yellow: return tr("Yellow", "Жёлтый")
        case .green: return tr("Green", "Зелёный")
        case .blue: return tr("Blue", "Синий")
        }
    }

    /// Stable English word, used in exports and filters.
    public var key: String {
        switch self {
        case .none: return ""
        case .red: return "red"
        case .yellow: return "yellow"
        case .green: return "green"
        case .blue: return "blue"
        }
    }
}

public enum SizeMetric: String, Codable, CaseIterable {
    case disk, logical
}

/// One element of the scanned tree. Owned and mutated by the main thread only.
public final class FileNode {
    public internal(set) var name: String
    public internal(set) weak var parent: FileNode?
    public internal(set) var kind: NodeKind
    public internal(set) var state: ScanState

    /// Folders: sum of descendants. Files: own size.
    public internal(set) var logicalSize: Int64 = 0
    public internal(set) var diskSize: Int64 = 0
    /// Number of descendant files (1 for a file).
    public internal(set) var fileCount: Int = 0

    /// Unix seconds, 0 when unknown.
    public internal(set) var created: Double = 0
    public internal(set) var modified: Double = 0
    public internal(set) var accessed: Double = 0
    public internal(set) var attributes: FileAttributes = []

    public var tag: Tag = .none
    /// When the element last changed on disk after its first listing (for blinking).
    public internal(set) var changedAt: Double = 0

    public internal(set) var children: [FileNode] = []

    /// Size under the active filter, in the active metric. Maintained by ScanSession.
    public internal(set) var filteredSize: Int64 = 0

    /// Disk size of the purgeable files in this subtree (the file's own size for a purgeable file).
    public internal(set) var purgeableSize: Int64 = 0

    public init(name: String, kind: NodeKind, state: ScanState = .done) {
        self.name = name
        self.kind = kind
        self.state = state
    }

    public var isContainer: Bool { kind == .volume || kind == .folder || kind == .mountPoint }
    public var isFile: Bool { kind == .file }
    public var isSynthetic: Bool { kind == .freeSpace || kind == .unknownSpace || kind == .purgeable }

    public func size(_ metric: SizeMetric) -> Int64 {
        metric == .disk ? diskSize : logicalSize
    }

    /// File extension, lowercased, without the dot. Empty for folders and names without one.
    public var fileExtension: String {
        guard isFile, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    public var root: FileNode {
        var n = self
        while let p = n.parent { n = p }
        return n
    }

    /// The root's name holds the full scanned path; children hold one component each.
    public var path: String {
        var parts: [String] = []
        var n = self
        while let p = n.parent {
            parts.append(n.name)
            n = p
        }
        let base = n.name
        if parts.isEmpty { return base }
        let tail = parts.reversed().joined(separator: "/")
        return base.hasSuffix("/") ? base + tail : base + "/" + tail
    }

    /// Short name for display: the last component for the root.
    public var displayName: String {
        guard parent == nil else { return name }
        if name == "/" { return "/" }
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// Self first, then parent, up to the root.
    public var ancestorsAndSelf: [FileNode] {
        var out: [FileNode] = [self]
        var n = self
        while let p = n.parent {
            out.append(p)
            n = p
        }
        return out
    }

    public func isDescendant(of other: FileNode) -> Bool {
        var n: FileNode? = self
        while let c = n {
            if c === other { return true }
            n = c.parent
        }
        return false
    }

    public func depth(below ancestor: FileNode) -> Int {
        var d = 0
        var n: FileNode? = self
        while let c = n, c !== ancestor {
            d += 1
            n = c.parent
        }
        return d
    }

    /// Own tag plus every ancestor's tag, as a bit mask.
    public var inheritedTagBits: UInt8 {
        var bits: UInt8 = 0
        var n: FileNode? = self
        while let c = n {
            bits |= c.tag.bit
            n = c.parent
        }
        return bits
    }

    public var containsFiles: Bool { children.contains { $0.isFile } }
    public var containsFolders: Bool { children.contains { $0.isContainer } }

    // MARK: Tree editing (main thread)

    func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    func removeChild(at index: Int) {
        children[index].parent = nil
        children.remove(at: index)
    }

    /// Adds the deltas to this node and every ancestor.
    func propagate(logical: Int64, disk: Int64, files: Int, purgeable: Int64 = 0) {
        guard logical != 0 || disk != 0 || files != 0 || purgeable != 0 else { return }
        var n: FileNode? = self
        while let c = n {
            c.logicalSize += logical
            c.diskSize += disk
            c.fileCount += files
            c.purgeableSize += purgeable
            n = c.parent
        }
    }

    func propagateFiltered(_ delta: Int64) {
        guard delta != 0 else { return }
        var n: FileNode? = self
        while let c = n {
            c.filteredSize += delta
            n = c.parent
        }
    }

    /// Recomputes folder aggregates bottom-up from the files. Used after loading.
    @discardableResult
    func recomputeAggregates() -> (Int64, Int64, Int) {
        guard isContainer else {
            if isFile { fileCount = 1 }
            purgeableSize = attributes.contains(.purgeable) ? diskSize : 0
            return (logicalSize, diskSize, isFile ? 1 : 0)
        }
        var l: Int64 = 0, d: Int64 = 0, f = 0, p: Int64 = 0
        for c in children {
            let r = c.recomputeAggregates()
            l += r.0; d += r.1; f += r.2
            p += c.purgeableSize
        }
        logicalSize = l
        diskSize = d
        fileCount = f
        purgeableSize = p
        return (l, d, f)
    }

    /// Builders used by importers and tests.
    public static func makeFile(_ name: String, logical: Int64, disk: Int64? = nil, modified: Double = 0) -> FileNode {
        let n = FileNode(name: name, kind: .file)
        n.logicalSize = logical
        n.diskSize = disk ?? logical
        n.fileCount = 1
        n.modified = modified
        return n
    }

    public static func makeFolder(_ name: String, _ children: [FileNode] = []) -> FileNode {
        let n = FileNode(name: name, kind: .folder)
        for c in children { n.addChild(c) }
        n.recomputeAggregates()
        return n
    }

    public func setAttributes(_ a: FileAttributes) { attributes = a }
    public func setDates(created: Double, modified: Double, accessed: Double) {
        self.created = created
        self.modified = modified
        self.accessed = accessed
    }
}
