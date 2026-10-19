import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where a scan may go.
public struct ScanOptions {
    /// Devices the scan may enter. nil = any device.
    public var allowedDevices: Set<Int32>?
    /// Absolute paths never entered.
    public var excludedPaths: Set<String>

    public init(allowedDevices: Set<Int32>? = nil, excludedPaths: Set<String> = []) {
        self.allowedDevices = allowedDevices
        self.excludedPaths = excludedPaths
    }

    /// Defaults for a root path. On APFS, `/` is the system volume and user data lives on
    /// `/System/Volumes/Data`, joined by firmlinks: allow both devices, skip the
    /// `/System/Volumes` mount tree so nothing is counted twice, and never wander into
    /// other drives under `/Volumes`.
    public static func forRoot(_ path: String, crossMountPoints: Bool) -> ScanOptions {
        var excluded: Set<String> = []
        var devices: Set<Int32> = []
        if let d = deviceID(path) { devices.insert(d) }
        if path == "/" {
            // Skip only what would be counted twice or isn't on this disk.
            excluded = ["/Volumes", "/dev", "/net", "/home", "/Network", "/System/Volumes/Data/Volumes"]
            // The Data volume is reached through firmlinks (/Users, /Applications…); its own
            // copies of those folders are skipped, the rest of it (Spotlight index, document
            // versions, update staging…) is scanned under /System/Volumes/Data.
            for target in firmlinkTargets() {
                excluded.insert("/System/Volumes/Data/" + target)
            }
            // Other volumes of the same APFS container (VM swap, Preboot, Update…) share its space.
            let rootTotal = containerSize("/")
            if let names = try? FileManager.default.contentsOfDirectory(atPath: "/System/Volumes") {
                for name in names {
                    let p = "/System/Volumes/" + name
                    guard let d = deviceID(p) else { continue }
                    if name == "Data" || (rootTotal > 0 && containerSize(p) == rootTotal) { devices.insert(d) }
                }
            }
        }
        return ScanOptions(allowedDevices: crossMountPoints ? nil : devices, excludedPaths: excluded)
    }

    /// Data-volume folders that appear at the root through firmlinks ("Users", "Applications"…).
    static func firmlinkTargets() -> [String] {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else {
            return ["Users", "Applications", "Library", "private", "usr/local", "opt", "cores", "System/Library/Caches"]
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { return nil }
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }

    static func containerSize(_ path: String) -> Int64 {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(v?.volumeTotalCapacity ?? 0)
    }

    public static func deviceID(_ path: String) -> Int32? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Int32(st.st_dev)
    }
}

struct EntryInfo {
    var name: String
    var isDir: Bool
    var logical: Int64
    var disk: Int64
    var created: Double
    var modified: Double
    var accessed: Double
    var attributes: FileAttributes
    /// A directory the scan does not enter (other device or excluded path).
    var blocked: Bool
}

struct WorkItem {
    let path: String
    let node: FileNode
    let token: Int
    let recursive: Bool
    let priority: Bool
}

struct Listing {
    let item: WorkItem
    var entries: [EntryInfo]
    var error: Int32
}

/// Lists directories on background threads. Never touches FileNode state:
/// the node in a WorkItem is only carried back as an identity for the merge.
final class ScanEngine {
    private let lock = NSLock()
    private var normal: [WorkItem] = []
    private var priority: [WorkItem] = []
    private var results: [Listing] = []
    private var workers = 0
    private var inFlight = 0
    private let maxWorkers: Int
    let options: ScanOptions

    private struct LinkKey: Hashable { let dev: Int32; let ino: UInt64 }
    private var linkOwners: [LinkKey: String] = [:]
    private let linkLock = NSLock()

    /// APFS clones (Finder copies, Preboot cryptexes…) share blocks. Each clone family is
    /// counted in full once, at the first path that saw it; the other members count only
    /// the blocks that are theirs alone.
    private struct CloneKey: Hashable { let dev: Int32; let id: UInt64 }
    private var cloneOwners: [CloneKey: String] = [:]
    /// Files smaller than this are not checked: clones of small files barely matter.
    static let cloneCheckMinimum: Int64 = 128 * 1024

    struct ExtInfo {
        let privateSize: Int64?
        let cloneID: UInt64
        let flags: UInt64
        var maySharBlocks: Bool { flags & 0x1 != 0 }   // EF_MAY_SHARE_BLOCKS
        var isPurgeable: Bool { flags & 0x8 != 0 }     // EF_IS_PURGEABLE
    }

    /// getattrlistat with the extended common attributes: private size, clone id, flags.
    /// nil when the volume doesn't support them (not APFS).
    static func extendedInfo(fd: Int32, name: UnsafePointer<CChar>) -> ExtInfo? {
        let ATTR_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
        let ATTR_CMNEXT_PRIVATESIZE: UInt32 = 0x0000_0008
        let ATTR_CMNEXT_CLONEID: UInt32 = 0x0000_0100
        let ATTR_CMNEXT_EXT_FLAGS: UInt32 = 0x0000_0200
        let FSOPT_NOFOLLOW: UInt = 0x1
        let FSOPT_ATTR_CMN_EXTENDED: UInt = 0x20

        var request = attrlist(bitmapcount: 5, reserved: 0,
                               commonattr: ATTR_CMN_RETURNED_ATTRS, volattr: 0, dirattr: 0, fileattr: 0,
                               forkattr: ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
        var buffer = [UInt8](repeating: 0, count: 64)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            getattrlistat(fd, name, &request, raw.baseAddress, raw.count, FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED) == 0
        }
        guard ok else { return nil }
        return buffer.withUnsafeBytes { raw -> ExtInfo? in
            // [u32 length][attribute_set_t: 5 × u32][privatesize: off_t][cloneid: u64][ext flags: u64]
            let returnedExt = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)   // forkattr word
            var offset = 24
            var privateSize: Int64?
            var cloneID: UInt64 = 0
            var flags: UInt64 = 0
            if returnedExt & ATTR_CMNEXT_PRIVATESIZE != 0 {
                privateSize = max(0, raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)); offset += 8
            }
            if returnedExt & ATTR_CMNEXT_CLONEID != 0 {
                cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self); offset += 8
            }
            if returnedExt & ATTR_CMNEXT_EXT_FLAGS != 0 {
                flags = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            } else {
                return nil
            }
            return ExtInfo(privateSize: privateSize, cloneID: cloneID, flags: flags)
        }
    }

    init(options: ScanOptions) {
        self.options = options
        maxWorkers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    }

    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return normal.isEmpty && priority.isEmpty && inFlight == 0 && results.isEmpty
    }

    func enqueue(_ items: [WorkItem]) {
        guard !items.isEmpty else { return }
        lock.lock()
        for item in items.reversed() {
            if item.priority { priority.append(item) } else { normal.append(item) }
        }
        var spawn = 0
        let queued = normal.count + priority.count
        while workers < maxWorkers && spawn < queued {
            workers += 1
            spawn += 1
        }
        lock.unlock()
        for _ in 0..<spawn {
            DispatchQueue.global(qos: .utility).async { [self] in workerLoop() }
        }
    }

    /// Drops queued work for a token. Returns how many items were dropped.
    func cancel(token: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let before = normal.count + priority.count
        normal.removeAll { $0.token == token }
        priority.removeAll { $0.token == token }
        return before - (normal.count + priority.count)
    }

    func drain(max: Int) -> [Listing] {
        lock.lock(); defer { lock.unlock() }
        guard !results.isEmpty else { return [] }
        let n = min(max, results.count)
        let out = Array(results[0..<n])
        results.removeFirst(n)
        return out
    }

    private func workerLoop() {
        while true {
            lock.lock()
            guard let item = priority.popLast() ?? normal.popLast() else {
                workers -= 1
                lock.unlock()
                return
            }
            inFlight += 1
            lock.unlock()

            let listing = list(item)

            lock.lock()
            results.append(listing)
            inFlight -= 1
            lock.unlock()
        }
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    private func list(_ item: WorkItem) -> Listing {
        let fd = open(item.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            return Listing(item: item, entries: [], error: errno)
        }
        guard let dir = fdopendir(fd) else {
            let e = errno
            close(fd)
            return Listing(item: item, entries: [], error: e)
        }
        defer { closedir(dir) }   // also closes fd
        var entries: [EntryInfo] = []
        var st = stat()

        while let ent = readdir(dir) {
            var info: EntryInfo?
            withUnsafePointer(to: ent.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ent.pointee.d_name)) { cname in
                    // skip "." and ".."
                    if cname[0] == 46 && (cname[1] == 0 || (cname[1] == 46 && cname[2] == 0)) { return }
                    guard fstatat(fd, cname, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                    info = makeEntry(name: String(cString: cname), st: st, dirPath: item.path, fd: fd, cname: cname)
                }
            }
            if let info { entries.append(info) }
        }
        return Listing(item: item, entries: entries, error: 0)
    }

    private func makeEntry(name: String, st: stat, dirPath: String, fd: Int32, cname: UnsafePointer<CChar>) -> EntryInfo {
        let type = st.st_mode & S_IFMT
        let isDir = type == S_IFDIR
        let isLink = type == S_IFLNK
        let flags = UInt32(st.st_flags)

        var attrs: FileAttributes = []
        if name.hasPrefix(".") || flags & 0x0000_8000 != 0 { attrs.insert(.hidden) }      // UF_HIDDEN
        if flags & (0x0000_0002 | 0x0002_0000) != 0 { attrs.insert(.locked) }            // UF_/SF_IMMUTABLE
        if flags & 0x0000_0020 != 0 { attrs.insert(.compressed) }                          // UF_COMPRESSED
        if flags & 0x0008_0000 != 0 { attrs.insert(.restricted) }                          // SF_RESTRICTED
        if flags & 0x4000_0000 != 0 { attrs.insert(.dataless) }                            // SF_DATALESS
        if isLink { attrs.insert(.symlink) }
        if !isDir && st.st_nlink > 1 { attrs.insert(.hardLink) }
        if !isDir && !isLink && (st.st_mode & 0o111) != 0 { attrs.insert(.executable) }

        var logical: Int64 = isDir ? 0 : Int64(st.st_size)
        var disk: Int64 = isDir ? 0 : Int64(st.st_blocks) * 512
        if isLink { logical = Int64(st.st_size) }

        var blocked = false
        if isDir {
            let full = ScanEngine.join(dirPath, name)
            if options.excludedPaths.contains(full) {
                blocked = true
            } else if let allowed = options.allowedDevices, !allowed.contains(Int32(st.st_dev)) {
                blocked = true
            }
        } else if attrs.contains(.hardLink) {
            // Count the blocks of a hard-linked file once, at the first path that saw it.
            let key = LinkKey(dev: Int32(st.st_dev), ino: UInt64(st.st_ino))
            let full = ScanEngine.join(dirPath, name)
            linkLock.lock()
            if let owner = linkOwners[key] {
                if owner != full { disk = 0 }
            } else {
                linkOwners[key] = full
            }
            linkLock.unlock()
        } else if !isLink && disk >= ScanEngine.cloneCheckMinimum,
                  let ext = ScanEngine.extendedInfo(fd: fd, name: cname) {
            if ext.isPurgeable { attrs.insert(.purgeable) }
            if ext.maySharBlocks, let priv = ext.privateSize, priv < disk {
                attrs.insert(.clone)
                let full = ScanEngine.join(dirPath, name)
                let key = CloneKey(dev: Int32(st.st_dev), id: ext.cloneID)
                linkLock.lock()
                if let owner = cloneOwners[key], owner != full {
                    disk = priv
                } else if ext.cloneID == 0 {
                    // No family id: count only what is certainly this file's own.
                    disk = priv
                } else {
                    cloneOwners[key] = full
                }
                linkLock.unlock()
            }
        }

        return EntryInfo(
            name: name,
            isDir: isDir,
            logical: logical,
            disk: disk,
            created: Double(st.st_birthtimespec.tv_sec),
            modified: Double(st.st_mtimespec.tv_sec),
            accessed: Double(st.st_atimespec.tv_sec),
            attributes: attrs,
            blocked: blocked
        )
    }
}
