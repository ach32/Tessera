import Foundation

/// Tessera snapshot file (.tessera):
///
///   "TSRA"            4 bytes magic
///   version           1 byte (1)
///   payload           LZFSE-compressed (NSData.compressed(using: .lzfse))
///
/// Payload, little-endian varints (zig-zag for signed):
///   root path         string
///   scan date         varint (unix seconds)
///   volume            u8 present; then name string, total varint, free varint, isVolumeRoot u8
///   nodes             pre-order: kind u8, name string, logical varint, disk varint,
///                     created/modified/accessed zigzag varints, attributes varint,
///                     tag u8, state u8, child count varint, then the children
/// Strings are varint byte length + UTF-8.
public enum SnapshotIO {
    public static let fileExtension = "tessera"
    static let magic: [UInt8] = Array("TSRA".utf8)

    public struct Loaded {
        public let root: FileNode
        public let volume: VolumeInfo?
        public let scanDate: Date
    }

    // MARK: Write

    /// Encodes `root` and what `include` lets through. Main thread (reads the tree).
    public static func encode(root: FileNode, rootPath: String, volume: VolumeInfo?,
                              include: @escaping (FileNode) -> Bool = { _ in true }) -> Data {
        var w = Writer()
        w.string(rootPath)
        w.uvar(UInt64(max(0, Date().timeIntervalSince1970)))
        if let v = volume {
            w.byte(1)
            w.string(v.name)
            w.uvar(UInt64(max(0, v.total)))
            w.uvar(UInt64(max(0, v.free)))
            w.byte(v.isVolumeRoot ? 1 : 0)
        } else {
            w.byte(0)
        }
        func node(_ n: FileNode, isRoot: Bool) {
            w.byte(n.kind.rawValue)
            w.string(isRoot ? rootPath : n.name)
            w.uvar(UInt64(max(0, n.logicalSize)))
            w.uvar(UInt64(max(0, n.diskSize)))
            w.svar(Int64(n.created))
            w.svar(Int64(n.modified))
            w.svar(Int64(n.accessed))
            w.uvar(UInt64(n.attributes.rawValue))
            w.byte(n.tag.rawValue)
            w.byte(n.state.rawValue)
            let kids = n.children.filter(include)
            w.uvar(UInt64(kids.count))
            for c in kids { node(c, isRoot: false) }
        }
        node(root, isRoot: true)
        return w.data
    }

    /// Compresses and writes. Safe off the main thread.
    public static func write(payload: Data, to url: URL) throws {
        let packed = try (payload as NSData).compressed(using: .lzfse) as Data
        var file = Data(magic)
        file.append(1)
        file.append(packed)
        try file.write(to: url, options: .atomic)
    }

    // MARK: Read

    public static func read(url: URL) throws -> Loaded {
        let file = try Data(contentsOf: url)
        guard file.count > 5, Array(file.prefix(4)) == magic else {
            throw FilterError(message: tr("\(url.lastPathComponent) is not a Tessera snapshot.", "\(url.lastPathComponent) — не снимок Tessera."))
        }
        guard file[file.startIndex + 4] == 1 else {
            throw FilterError(message: tr("\(url.lastPathComponent) was written by a newer version of Tessera.", "\(url.lastPathComponent) создан более новой версией Tessera."))
        }
        let packed = file.dropFirst(5)
        let payload = try (Data(packed) as NSData).decompressed(using: .lzfse) as Data
        var r = Reader(Array(payload))
        _ = try r.string()   // root path; the root node carries it too
        let date = Date(timeIntervalSince1970: Double(try r.uvar()))
        var volume: VolumeInfo?
        if try r.byte() == 1 {
            let name = try r.string()
            let total = Int64(try r.uvar())
            let free = Int64(try r.uvar())
            let isRoot = try r.byte() == 1
            volume = VolumeInfo(name: name, total: total, free: free, isVolumeRoot: isRoot)
        }
        func node() throws -> FileNode {
            guard let kind = NodeKind(rawValue: try r.byte()) else { throw FilterError(message: tr("Damaged snapshot (kind).", "Снимок повреждён (тип).")) }
            let n = FileNode(name: try r.string(), kind: kind)
            n.logicalSize = Int64(try r.uvar())
            n.diskSize = Int64(try r.uvar())
            n.created = Double(try r.svar())
            n.modified = Double(try r.svar())
            n.accessed = Double(try r.svar())
            n.attributes = FileAttributes(rawValue: UInt16(truncatingIfNeeded: try r.uvar()))
            n.tag = Tag(rawValue: try r.byte()) ?? .none
            n.state = ScanState(rawValue: try r.byte()) ?? .done
            let count = Int(try r.uvar())
            guard count <= r.remaining else { throw FilterError(message: tr("Damaged snapshot (count).", "Снимок повреждён (количество).")) }
            n.children.reserveCapacity(count)
            for _ in 0..<count { n.addChild(try node()) }
            return n
        }
        let root = try node()
        root.recomputeAggregates()
        return Loaded(root: root, volume: volume, scanDate: date)
    }

    // MARK: Varints

    struct Writer {
        var data = Data()
        mutating func byte(_ b: UInt8) { data.append(b) }
        mutating func uvar(_ v: UInt64) {
            var x = v
            while x >= 0x80 {
                data.append(UInt8(x & 0x7F) | 0x80)
                x >>= 7
            }
            data.append(UInt8(x))
        }
        mutating func svar(_ v: Int64) { uvar(UInt64(bitPattern: (v << 1) ^ (v >> 63))) }
        mutating func string(_ s: String) {
            let bytes = Array(s.utf8)
            uvar(UInt64(bytes.count))
            data.append(contentsOf: bytes)
        }
    }

    struct Reader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }
        var remaining: Int { b.count - i }

        mutating func byte() throws -> UInt8 {
            guard i < b.count else { throw FilterError(message: tr("Snapshot ends too early.", "Снимок обрывается раньше времени.")) }
            defer { i += 1 }
            return b[i]
        }
        mutating func uvar() throws -> UInt64 {
            var shift: UInt64 = 0
            var out: UInt64 = 0
            while true {
                let x = try byte()
                out |= UInt64(x & 0x7F) << shift
                if x & 0x80 == 0 { return out }
                shift += 7
                if shift > 63 { throw FilterError(message: tr("Damaged snapshot (number).", "Снимок повреждён (число).")) }
            }
        }
        mutating func svar() throws -> Int64 {
            let u = try uvar()
            return Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
        }
        mutating func string() throws -> String {
            let n = Int(try uvar())
            guard n <= remaining else { throw FilterError(message: tr("Damaged snapshot (text).", "Снимок повреждён (текст).")) }
            defer { i += n }
            return String(decoding: b[i..<(i + n)], as: UTF8.self)
        }
    }
}

/// Reads `du -ak` style output ("<KiB>\t<path>" per line, children before parents).
/// Without -a, each folder gets a "(files)" element for what its subfolders do not explain.
public enum DuImporter {
    public static func read(text: String, blockSize: Int64 = 1024) throws -> FileNode {
        var entries: [(String, Int64)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let n = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            var path = String(parts[1])
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            entries.append((path, n * blockSize))
        }
        guard !entries.isEmpty else { throw FilterError(message: tr("No “size<TAB>path” lines found. Make the file with: du -ak /some/folder > scan.du", "Не найдено строк «размер<TAB>путь». Создайте файл так: du -ak /папка > scan.du")) }

        // The root is the shortest path that prefixes every other one; du prints it last.
        let rootPath = entries.min(by: { $0.0.count < $1.0.count })!.0
        let root = FileNode(name: rootPath, kind: .folder)
        var reported: [ObjectIdentifier: Int64] = [ObjectIdentifier(root): 0]
        var lookup: [String: FileNode] = [rootPath: root]

        func nodeFor(_ path: String) -> FileNode? {
            if let n = lookup[path] { return n }
            guard path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") || (rootPath == "." && !path.hasPrefix("/")) else { return nil }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = (parentPath == path || parentPath.isEmpty) ? root : (nodeFor(parentPath) ?? root)
            let n = FileNode(name: (path as NSString).lastPathComponent, kind: .file)
            parent.addChild(n)
            lookup[path] = n
            return n
        }

        for (path, size) in entries {
            if path == rootPath {
                reported[ObjectIdentifier(root)] = size
                continue
            }
            guard let n = nodeFor(path) else { continue }
            reported[ObjectIdentifier(n)] = size
        }

        // Anything with children is a folder; leaves are files with their reported size.
        func finish(_ n: FileNode) {
            if n.children.isEmpty && n !== root {
                n.kind = .file
                let s = reported[ObjectIdentifier(n)] ?? 0
                n.logicalSize = s
                n.diskSize = s
                n.fileCount = 1
                return
            }
            n.kind = .folder
            for c in n.children { finish(c) }
        }
        finish(root)
        root.recomputeAggregates()

        // Folders whose du total is larger than their children: add the rest as one element.
        func fill(_ n: FileNode) {
            guard n.isContainer else { return }
            for c in n.children where c.isContainer { fill(c) }
            let total = reported[ObjectIdentifier(n)] ?? 0
            let sum = n.children.reduce(Int64(0)) { $0 + $1.diskSize }
            if total > sum {
                let rest = FileNode(name: tr("(files)", "(файлы)"), kind: .file)
                rest.logicalSize = total - sum
                rest.diskSize = total - sum
                rest.fileCount = 1
                n.addChild(rest)
                n.diskSize = total
                n.logicalSize = total
            }
        }
        fill(root)
        root.recomputeAggregates()
        return root
    }
}
