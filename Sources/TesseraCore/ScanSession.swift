import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct VolumeInfo: Equatable {
    public var name: String
    public var total: Int64
    public var free: Int64
    /// The scanned path is the volume's mount point.
    public var isVolumeRoot: Bool
    /// Space counted as used that macOS frees on its own when it needs room
    /// (local Time Machine snapshots, iCloud-cached files, some caches).
    public var purgeable: Int64
    public var used: Int64 { max(0, total - free) }

    public init(name: String, total: Int64, free: Int64, isVolumeRoot: Bool, purgeable: Int64 = 0) {
        self.name = name
        self.total = total
        self.free = free
        self.isVolumeRoot = isVolumeRoot
        self.purgeable = purgeable
    }

    public static func read(path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        let isRoot = v.volume.map { $0.standardizedFileURL.path == url.standardizedFileURL.path } ?? false
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        // "Available for important usage" is what Finder shows: free + purgeable.
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        return VolumeInfo(name: v.volumeName ?? path,
                          total: Int64(v.volumeTotalCapacity ?? 0),
                          free: free,
                          isVolumeRoot: isRoot,
                          purgeable: max(0, important - free))
    }
}

public struct LogEntry: Identifiable {
    public let id = UUID()
    public let date: Date
    public let path: String
    public let message: String
    public let hint: String?
    /// A system folder no ordinary app can read (owned by another user, or SIP).
    /// Normal; shown grouped and never pops the log open.
    public let expected: Bool

    public init(date: Date = Date(), path: String, message: String, hint: String? = nil, expected: Bool = false) {
        self.date = date
        self.path = path
        self.message = message
        self.hint = hint
        self.expected = expected
    }
}

/// One scanned (or loaded) tree, its scans, its live link to the disk and its filter.
/// Lives on the main thread.
@MainActor
public final class ScanSession: NSObject {
    public let root: FileNode
    public let rootPath: String
    public private(set) var volume: VolumeInfo?
    /// Set when the tree came from a file: no live link, no rescans.
    public let snapshotName: String?
    public var isSnapshot: Bool { snapshotName != nil }

    public var onChange: (() -> Void)?
    public var onLog: ((LogEntry) -> Void)?
    public var onFinished: (() -> Void)?
    public var logWarnings = true

    public var sizeMetric: SizeMetric = .disk {
        didSet { if oldValue != sizeMetric { recomputeFilter() } }
    }
    public private(set) var filter: CompiledFilter?

    public let freeNode = FileNode(name: "Free space", kind: .freeSpace)
    public let unknownNode = FileNode(name: "Not scanned or inaccessible", kind: .unknownSpace)
    public let purgeableNode = FileNode(name: "Purgeable", kind: .purgeable)

    /// When scanning "/": how much APFS says each extra volume of the container really uses
    /// (mount path → bytes). Files on Preboot share blocks as APFS clones, so their sizes
    /// add up to more than the volume holds.
    public private(set) var volumeConsumed: [String: Int64] = [:]

    public private(set) var masterToken: Int?
    public private(set) var subToken: Int?
    public private(set) var subScanNode: FileNode?
    public private(set) var deniedCount = 0
    public private(set) var folderCount = 0
    public private(set) var scanStarted: Date?
    public private(set) var lastScanDuration: TimeInterval?
    public private(set) var lastChange: Double = 0

    private var engine: ScanEngine?
    private var timer: Timer?
    private var watcher: FSWatcher?
    private var nextToken = 1
    private var pending: [Int: Int] = [:]
    private var activeTokens: Set<Int> = [0]
    private var lastVolumeRead: Double = 0

    // MARK: Life

    /// A live scan of `path` (not started yet: call `startMasterScan`).
    public init(path: String, options: ScanOptions? = nil, watchChanges: Bool = true) {
        let clean = ScanSession.normalize(path)
        rootPath = clean
        let vol = VolumeInfo.read(path: clean)
        volume = vol
        let kind: NodeKind = (vol?.isVolumeRoot ?? false) ? .volume : .folder
        root = FileNode(name: clean, kind: kind, state: .pending)
        snapshotName = nil
        super.init()
        engine = ScanEngine(options: options ?? ScanOptions.forRoot(clean, crossMountPoints: false))
        if watchChanges {
            watcher = FSWatcher(path: clean, latency: 1.0) { [weak self] events in
                self?.handleFileSystemEvents(events)
            }
        }
        startTimer()
        if clean == "/" { loadVolumeConsumption() }
    }

    private func loadVolumeConsumption() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let map = ScanSession.readVolumeConsumption()
            DispatchQueue.main.async {
                self?.volumeConsumed = map
                self?.onChange?()
            }
        }
    }

    /// Mount path → "Capacity In Use" for the non-System, non-Data volumes of the boot container.
    nonisolated static func readVolumeConsumption() -> [String: Int64] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return [:] }

        // device ("disk3s2") → used bytes
        var used: [String: Int64] = [:]
        for c in containers {
            for v in (c["Volumes"] as? [[String: Any]]) ?? [] {
                guard let dev = v["DeviceIdentifier"] as? String else { continue }
                let roles = (v["Roles"] as? [String]) ?? []
                if roles.contains("System") || roles.contains("Data") { continue }
                if let n = v["CapacityInUse"] as? Int64 { used[dev] = n }
                else if let n = v["CapacityInUse"] as? Int { used[dev] = Int64(n) }
            }
        }
        // mount path → device, for what is mounted under /System/Volumes
        var out: [String: Int64] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Volumes")) ?? []
        for name in names {
            let path = "/System/Volumes/" + name
            var fs = statfs()
            guard statfs(path, &fs) == 0 else { continue }
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let onPath = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard onPath == path else { continue }   // not a mount point itself
            let dev = from.hasPrefix("/dev/") ? String(from.dropFirst(5)) : from
            if let n = used[dev] { out[path] = n }
        }
        return out
    }

    /// Bytes the scan counts twice on volumes whose files share blocks (see `volumeConsumed`).
    public var cloneOvercount: Int64 {
        var extra: Int64 = 0
        for (path, consumed) in volumeConsumed {
            if let hit = deepestNode(for: path), hit.1 {
                extra += max(0, hit.0.diskSize - consumed)
            }
        }
        return extra
    }

    /// A loaded snapshot.
    public init(snapshotRoot: FileNode, name: String, volume: VolumeInfo?) {
        root = snapshotRoot
        rootPath = snapshotRoot.name
        self.volume = volume
        snapshotName = name
        super.init()
    }

    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    /// Stops everything. Call when the window closes.
    public func close() {
        stopScan()
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        onChange = nil
        onLog = nil
        onFinished = nil
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Scans

    public var isScanning: Bool { masterToken != nil || subToken != nil }
    public var canScan: Bool { engine != nil }

    /// Fraction of the volume's used space seen so far. Nil when the root is not a volume.
    public var progress: Double? {
        guard let v = volume, v.isVolumeRoot, v.used > 0 else { return nil }
        return min(1, Double(root.diskSize) / Double(v.used))
    }

    public func startMasterScan() {
        guard engine != nil, masterToken == nil else { return }
        let t = newToken()
        masterToken = t
        scanStarted = Date()
        enqueue([root], paths: [rootPath], token: t, recursive: true, priority: false)
        onChange?()
    }

    /// Scans the zoomed folder ahead of the master scan. One at a time.
    public func startSubScan(_ node: FileNode) {
        guard engine != nil, node.isContainer, node.kind != .mountPoint else { return }
        if node === root { startMasterScan(); return }
        if let s = subToken { cancel(token: s) }
        let t = newToken()
        subToken = t
        subScanNode = node
        enqueue([node], paths: [node.path], token: t, recursive: true, priority: true)
        onChange?()
    }

    public func stopScan() {
        if let t = masterToken { cancel(token: t) }
        if let t = subToken { cancel(token: t) }
        onChange?()
    }

    public func stopSubScan() {
        if let t = subToken { cancel(token: t) }
        onChange?()
    }

    static func ownerUID(_ path: String) -> uid_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_uid
    }

    /// Re-lists one folder (new subfolders are scanned in full).
    public func refresh(_ node: FileNode, recursive: Bool = false) {
        guard engine != nil else { return }
        let target = node.isContainer ? node : (node.parent ?? root)
        guard target.kind != .mountPoint else { return }
        enqueue([target], paths: [target.path], token: 0, recursive: recursive, priority: true)
    }

    private func newToken() -> Int {
        let t = nextToken
        nextToken += 1
        activeTokens.insert(t)
        return t
    }

    private func enqueue(_ nodes: [FileNode], paths: [String], token: Int, recursive: Bool, priority: Bool) {
        guard let engine, !nodes.isEmpty else { return }
        var items: [WorkItem] = []
        items.reserveCapacity(nodes.count)
        for (i, n) in nodes.enumerated() {
            items.append(WorkItem(path: paths[i], node: n, token: token, recursive: recursive, priority: priority))
        }
        pending[token, default: 0] += items.count
        engine.enqueue(items)
    }

    private func cancel(token: Int) {
        guard token != 0 else { return }
        activeTokens.remove(token)
        if let engine {
            let dropped = engine.cancel(token: token)
            pending[token, default: 0] -= dropped
        }
        if masterToken == token {
            masterToken = nil
            if let s = scanStarted { lastScanDuration = Date().timeIntervalSince(s) }
        }
        if subToken == token {
            subToken = nil
            subScanNode = nil
        }
        if (pending[token] ?? 0) <= 0 { pending[token] = nil }
    }

    private func itemDone(token: Int) {
        let left = (pending[token] ?? 1) - 1
        if left > 0 {
            pending[token] = left
            return
        }
        pending[token] = nil
        guard token != 0 else { return }
        let wasMaster = masterToken == token
        if wasMaster {
            masterToken = nil
            if let s = scanStarted { lastScanDuration = Date().timeIntervalSince(s) }
        }
        if subToken == token {
            subToken = nil
            subScanNode = nil
        }
        activeTokens.remove(token)
        if wasMaster { onFinished?() }
    }

    @objc private func tick(_ t: Timer) {
        guard let engine else { return }
        let start = CFAbsoluteTimeGetCurrent()
        var changed = false
        while CFAbsoluteTimeGetCurrent() - start < 0.025 {
            let batch = engine.drain(max: 32)
            if batch.isEmpty { break }
            for l in batch { merge(l) }
            changed = true
        }
        let now = Date().timeIntervalSince1970
        if now - lastVolumeRead > 3 {
            lastVolumeRead = now
            if let v = VolumeInfo.read(path: rootPath), v != volume {
                volume = v
                changed = true
            }
        }
        if changed {
            lastChange = now
            onChange?()
        }
    }

    // MARK: Merge (main thread)

    private func merge(_ l: Listing) {
        defer { itemDone(token: l.item.token) }
        let dir = l.item.node
        guard dir.root === root else { return }   // removed while it was being listed

        if l.error != 0 {
            let denied = l.error == EACCES || l.error == EPERM
            if l.error == ENOENT, let p = dir.parent, let i = p.children.firstIndex(where: { $0 === dir }) {
                removeChildren(of: p, at: [i])
                return
            }
            let alreadyReported = dir.state == .denied
            if !alreadyReported && denied { deniedCount += 1 }
            dir.state = denied ? .denied : .done
            // Report a folder once, not on every rescan or disk event.
            if logWarnings && !alreadyReported {
                let msg = String(cString: strerror(l.error))
                let hint: String?
                switch l.error {
                case EPERM:
                    hint = tr("Blocked by macOS (privacy protection or System Integrity Protection). Full Disk Access unlocks privacy-protected folders; SIP-protected ones stay closed to every app.",
                              "Закрыто macOS (защита конфиденциальности или SIP). Полный доступ к диску открывает папки, защищённые конфиденциальностью; папки под SIP закрыты для всех приложений.")
                case EACCES:
                    hint = tr("Blocked by file permissions: the folder belongs to another user or to the system. Full Disk Access doesn't change this.",
                              "Закрыто правами доступа: папка принадлежит другому пользователю или системе. Полный доступ к диску на это не влияет.")
                default:
                    hint = nil
                }
                let expected = l.error == EPERM
                    || (l.error == EACCES && ScanSession.ownerUID(l.item.path).map { $0 != getuid() } ?? false)
                onLog?(LogEntry(path: l.item.path, message: tr("Can't read folder: \(msg) [errno \(l.error)]", "Не удалось прочитать папку: \(msg) [errno \(l.error)]"),
                                hint: hint, expected: expected))
            }
            return
        }

        let initial = dir.state == .pending
        let now = Date().timeIntervalSince1970
        let metric = sizeMetric
        let f = filter
        let ctx = f?.context(for: dir)

        let oldCount = dir.children.count
        var index: [String: Int] = [:]
        if oldCount > 0 {
            index.reserveCapacity(oldCount)
            for (i, c) in dir.children.enumerated() { index[c.name] = i }
        }
        var seen = [Bool](repeating: false, count: oldCount)
        var dl: Int64 = 0, dd: Int64 = 0, df = 0
        var dp: Int64 = 0   // purgeable
        var dFiltered: Int64 = 0
        var newDirs: [FileNode] = []
        var oldDirs: [FileNode] = []

        for e in l.entries {
            if let i = index[e.name] {
                let c = dir.children[i]
                if c.isContainer == e.isDir {
                    seen[i] = true
                    let oldPurgeable = c.isFile ? c.purgeableSize : 0
                    c.created = e.created
                    c.modified = e.modified
                    c.accessed = e.accessed
                    c.attributes = e.attributes
                    if e.isDir {
                        if !e.blocked && c.kind != .mountPoint { oldDirs.append(c) }
                    } else {
                        if c.logicalSize != e.logical || c.diskSize != e.disk { c.changedAt = now }
                        dl += e.logical - c.logicalSize
                        dd += e.disk - c.diskSize
                        c.logicalSize = e.logical
                        c.diskSize = e.disk
                        c.purgeableSize = e.attributes.contains(.purgeable) ? e.disk : 0
                        dp += c.purgeableSize - oldPurgeable
                        if let f, let ctx {
                            let v = f.matches(c, in: ctx) ? c.size(metric) : 0
                            dFiltered += v - c.filteredSize
                            c.filteredSize = v
                        }
                    }
                    continue
                }
                // Same name, different type: the old one goes, the new one is added below.
            }
            let kind: NodeKind = e.isDir ? (e.blocked ? .mountPoint : .folder) : .file
            let c = FileNode(name: e.name, kind: kind, state: (e.isDir && !e.blocked) ? .pending : .done)
            c.created = e.created
            c.modified = e.modified
            c.accessed = e.accessed
            c.attributes = e.attributes
            if !initial { c.changedAt = now }
            if !e.isDir {
                c.logicalSize = e.logical
                c.diskSize = e.disk
                c.fileCount = 1
                dl += e.logical
                dd += e.disk
                df += 1
                if e.attributes.contains(.purgeable) {
                    c.purgeableSize = e.disk
                    dp += e.disk
                }
                if let f, let ctx, f.matches(c, in: ctx) {
                    c.filteredSize = c.size(metric)
                    dFiltered += c.filteredSize
                }
            } else if kind == .folder {
                newDirs.append(c)
            }
            dir.addChild(c)
        }

        // Gone from disk.
        var gone: [Int] = []
        for i in 0..<oldCount where !seen[i] { gone.append(i) }
        if !gone.isEmpty {
            for i in gone.reversed() {
                let c = dir.children[i]
                dl -= c.logicalSize
                dd -= c.diskSize
                df -= c.fileCount
                dp -= c.purgeableSize
                dFiltered -= c.filteredSize
                dir.removeChild(at: i)
            }
        }

        dir.propagate(logical: dl, disk: dd, files: df, purgeable: dp)
        if f != nil { dir.propagateFiltered(dFiltered) }
        if initial { folderCount += 1 }
        dir.state = .done

        let token = l.item.token
        guard activeTokens.contains(token) else { return }
        var next = newDirs
        if l.item.recursive { next += oldDirs }
        if !next.isEmpty {
            let paths = next.map { ScanEngine.join(l.item.path, $0.name) }
            enqueue(next, paths: paths, token: token, recursive: true, priority: l.item.priority)
        }
    }

    private func removeChildren(of dir: FileNode, at indices: [Int]) {
        var dl: Int64 = 0, dd: Int64 = 0, df = 0, dF: Int64 = 0, dp: Int64 = 0
        for i in indices.sorted(by: >) {
            let c = dir.children[i]
            dl -= c.logicalSize; dd -= c.diskSize; df -= c.fileCount; dF -= c.filteredSize; dp -= c.purgeableSize
            dir.removeChild(at: i)
        }
        dir.propagate(logical: dl, disk: dd, files: df, purgeable: dp)
        if filter != nil { dir.propagateFiltered(dF) }
        lastChange = Date().timeIntervalSince1970
    }

    /// Takes a node out of the tree right away (after it was moved to the Trash).
    public func remove(_ node: FileNode) {
        guard let p = node.parent, let i = p.children.firstIndex(where: { $0 === node }) else { return }
        removeChildren(of: p, at: [i])
        onChange?()
    }

    // MARK: Live changes

    private func handleFileSystemEvents(_ events: [(String, Bool)]) {
        var targets: [ObjectIdentifier: (FileNode, Bool)] = [:]
        for (raw, mustScanSubDirs) in events {
            var p = raw
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            // Firmlinked Data-volume paths are shown at the root (/Users/…); the rest of the
            // Data volume (Spotlight index etc.) stays under /System/Volumes/Data.
            if rootPath == "/" && p.hasPrefix("/System/Volumes/Data/"),
               let ex = engine?.options.excludedPaths,
               ex.contains(where: { $0.hasPrefix("/System/Volumes/Data/") && (p == $0 || p.hasPrefix($0 + "/")) }) {
                p = String(p.dropFirst("/System/Volumes/Data".count))
            }
            guard let hit = deepestNode(for: p) else { continue }
            let (node, exact) = hit
            let target = node.isContainer ? node : (node.parent ?? root)
            let recursive = mustScanSubDirs || !exact
            let key = ObjectIdentifier(target)
            targets[key] = (target, (targets[key]?.1 ?? false) || recursive)
        }
        for entry in targets.values {
            let (node, recursive) = entry
            if (node.state != .pending && node.state != .denied) || node === root {
                refresh(node, recursive: recursive)
            }
        }
    }

    /// The deepest existing node on the way to `path`, and whether it is the path itself.
    func deepestNode(for path: String) -> (FileNode, Bool)? {
        let rel: Substring
        if path == rootPath {
            return (root, true)
        } else if rootPath == "/" {
            guard path.hasPrefix("/") else { return nil }
            if let ex = engine?.options.excludedPaths, ex.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return nil }
            rel = path.dropFirst()
        } else if path.hasPrefix(rootPath + "/") {
            rel = path.dropFirst(rootPath.count + 1)
        } else {
            return nil
        }
        var node = root
        for comp in rel.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return (node, false) }
            node = next
        }
        return (node, true)
    }

    // MARK: Filter

    public func setFilter(_ f: CompiledFilter?) {
        filter = f
        recomputeFilter()
        onChange?()
    }

    public func recomputeFilter() {
        guard let f = filter else { return }
        _ = recompute(root, f, f.rootContext)
    }

    private func recompute(_ node: FileNode, _ f: CompiledFilter, _ ctx: FolderContext) -> Int64 {
        if node.isFile {
            let v = f.matches(node, in: ctx) ? node.size(sizeMetric) : 0
            node.filteredSize = v
            return v
        }
        let inner = f.extend(ctx, with: node)
        var sum: Int64 = 0
        for c in node.children { sum += recompute(c, f, inner) }
        node.filteredSize = sum
        return sum
    }

    /// Area weight of a node in the current metric and filter.
    public func weight(_ n: FileNode) -> Int64 {
        if n.isSynthetic { return n.diskSize }
        return filter == nil ? n.size(sizeMetric) : n.filteredSize
    }

    /// Free and unknown space elements for the root, sized from the volume.
    public func extras(showFree: Bool, showUnknown: Bool) -> [(FileNode, Int64)] {
        guard let v = volume, v.isVolumeRoot else { return [] }
        var out: [(FileNode, Int64)] = []
        freeNode.name = tr("Free space", "Свободно")
        unknownNode.name = tr("Not scanned or inaccessible", "Не просканировано или недоступно")
        purgeableNode.name = tr("Purgeable (macOS frees it when needed)", "Очищаемое (macOS освободит само)")
        if showFree && v.free > 0 {
            freeNode.diskSize = v.free
            freeNode.logicalSize = v.free
            out.append((freeNode, v.free))
        }
        // Purgeable space is "used" on paper but behaves like free space. Part of it is files
        // the scan finds (marked purgeable by APFS: iCloud and media caches); only the rest —
        // local snapshots and the like — gets its own block, and only once the scan is done,
        // so it doesn't appear and then vanish while files are still being found.
        let outsideScan = max(0, v.purgeable - root.purgeableSize)
        let seen = max(0, root.diskSize - cloneOvercount)   // what the scan found, shared blocks counted once
        let purgeable = masterToken != nil ? 0 : min(outsideScan, max(0, v.used - seen))
        if showFree && purgeable > 0 {
            purgeableNode.diskSize = purgeable
            purgeableNode.logicalSize = purgeable
            out.append((purgeableNode, purgeable))
        }
        if showUnknown {
            let unknown = max(0, v.used - seen - purgeable)
            unknownNode.diskSize = unknown
            unknownNode.logicalSize = unknown
            if unknown > 0 { out.append((unknownNode, unknown)) }
        }
        return out
    }

    // MARK: Tags

    public func toggleTag(_ tag: Tag, on node: FileNode) {
        guard !node.isSynthetic else { return }
        node.tag = node.tag == tag ? .none : tag
        if filter?.usesTags == true { recomputeFilter() }
        onChange?()
    }

    /// Clears every tag under (and on) `node`, including elements hidden by the filter.
    public func clearTags(under node: FileNode) {
        func clear(_ n: FileNode) {
            n.tag = .none
            for c in n.children { clear(c) }
        }
        clear(node)
        if filter?.usesTags == true { recomputeFilter() }
        onChange?()
    }
}

extension CompiledFilter {
    var rootContext: FolderContext {
        FolderContext(included: includeFolders.isEmpty, excluded: false, tagBits: 0)
    }

    /// The context for the children of `dir`, given the context `dir` itself sits in.
    func extend(_ ctx: FolderContext, with dir: FileNode) -> FolderContext {
        var c = ctx
        c.tagBits |= dir.tag.bit
        if dir.parent != nil && dir.isContainer {
            if !c.included && includeFolders.contains(where: { $0.matches(dir.name) }) { c.included = true }
            if !c.excluded && excludeFolders.contains(where: { $0.matches(dir.name) }) { c.excluded = true }
        }
        return c
    }
}
