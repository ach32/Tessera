import XCTest
@testable import TesseraCore

final class GlobTests: XCTestCase {
    func testWildcards() {
        XCTAssertTrue(Glob("*.jpg").matches("Photo.JPG"))
        XCTAssertFalse(Glob("*.jpg").matches("photo.jpeg"))
        XCTAssertTrue(Glob("img_??.png").matches("IMG_01.png"))
        XCTAssertFalse(Glob("img_??.png").matches("IMG_001.png"))
        XCTAssertTrue(Glob("*cache*").matches("com.apple.Cache.db"))
        XCTAssertTrue(Glob("a*b*c").matches("aXXbYYc"))
        XCTAssertFalse(Glob("a*b*c").matches("aXXbYY"))
    }

    func testPlainWordMatchesAnywhere() {
        XCTAssertTrue(Glob("backup").matches("old-Backup-2019.zip"))
    }

    func testFuzzy() {
        XCTAssertEqual(Fuzzy.pick("dsksz", FilterParser.sizeKeywords), .disk)
        XCTAssertEqual(Fuzzy.pick("disk", FilterParser.sizeKeywords), .disk)
        XCTAssertEqual(Fuzzy.pick("size", FilterParser.sizeKeywords), .logical)
        XCTAssertNil(Fuzzy.pick("zzz", FilterParser.sizeKeywords))
    }
}

final class FilterTests: XCTestCase {
    let now = 1_700_000_000.0

    func tree() -> (FileNode, [String: FileNode]) {
        let day = 86400.0
        let a = FileNode.makeFile("holiday.jpg", logical: 5_000_000, modified: now - 10 * day)
        let b = FileNode.makeFile("notes.txt", logical: 2_000, modified: now - 400 * day)
        let c = FileNode.makeFile("movie.mov", logical: 2_000_000_000, modified: now - 40 * day)
        let d = FileNode.makeFile("old.jpg", logical: 50_000, modified: now - 800 * day)
        let tmp = FileNode.makeFolder("Temp", [d])
        let pics = FileNode.makeFolder("Pictures", [a, tmp])
        let root = FileNode.makeFolder("/Users/me", [pics, b, c])
        return (root, ["a": a, "b": b, "c": c, "d": d, "tmp": tmp, "pics": pics])
    }

    func visible(_ filter: String, classes: [FileClass] = FileClass.defaults) throws -> Set<String> {
        let (root, _) = tree()
        return try visible(filter, root: root, classes: classes)
    }

    func visible(_ filter: String, root: FileNode, classes: [FileClass] = FileClass.defaults) throws -> Set<String> {
        let f = try XCTUnwrap(FilterParser.parse(filter, classes: classes, now: now))
        var out: Set<String> = []
        func walk(_ n: FileNode) {
            if n.isFile {
                if f.matches(n, in: f.context(for: n.parent!)) { out.insert(n.name) }
            }
            n.children.forEach(walk)
        }
        walk(root)
        return out
    }

    func testEmpty() throws {
        XCTAssertNil(try FilterParser.parse("  ;  "))
    }

    func testMasksAreOred() throws {
        XCTAssertEqual(try visible("*.jpg;*.txt"), ["holiday.jpg", "old.jpg", "notes.txt"])
    }

    func testNegation() throws {
        XCTAssertEqual(try visible("|*.jpg"), ["notes.txt", "movie.mov"])
    }

    func testSize() throws {
        XCTAssertEqual(try visible(">1mb"), ["holiday.jpg", "movie.mov"])
        XCTAssertEqual(try visible("size > 10 mb"), ["movie.mov"])
        XCTAssertEqual(try visible("<10kb"), ["notes.txt"])
        XCTAssertEqual(try visible("*.jpg;>1mb"), ["holiday.jpg"])
    }

    func testAge() throws {
        XCTAssertEqual(try visible(">1year"), ["notes.txt", "old.jpg"])
        XCTAssertEqual(try visible("<6months"), ["holiday.jpg", "movie.mov"])
        XCTAssertEqual(try visible("modified<2weeks"), ["holiday.jpg"])
    }

    func testFolderMask() throws {
        XCTAssertEqual(try visible("\\temp"), ["old.jpg"])
        XCTAssertEqual(try visible("|\\temp;*.jpg"), ["holiday.jpg"])
        XCTAssertEqual(try visible("\\pict*;*.jpg"), ["holiday.jpg", "old.jpg"])
    }

    func testTagsInheritFromFolders() throws {
        let (root, n) = tree()
        n["tmp"]!.tag = .green
        XCTAssertEqual(try visible(":green", root: root), ["old.jpg"])
        XCTAssertEqual(try visible(":tag:g", root: root), ["old.jpg"])
        XCTAssertEqual(try visible("|:3", root: root), ["holiday.jpg", "notes.txt", "movie.mov"])
        n["c"]!.tag = .red
        XCTAssertEqual(try visible(":all", root: root), ["old.jpg", "movie.mov"])
        XCTAssertEqual(try visible(":tag:red+green-g", root: root), ["movie.mov"])
    }

    func testClass() throws {
        XCTAssertEqual(try visible(":class:images"), ["holiday.jpg", "old.jpg"])
        XCTAssertEqual(try visible("|:class:Video"), ["holiday.jpg", "old.jpg", "notes.txt"])
        XCTAssertThrowsError(try FilterParser.parse(":class:nope"))
    }

    func testAttributes() throws {
        let (root, n) = tree()
        n["b"]!.setAttributes([.hidden])
        XCTAssertEqual(try visible(":attr:hidden", root: root), ["notes.txt"])
        XCTAssertEqual(try visible("|:attr:h", root: root), ["holiday.jpg", "old.jpg", "movie.mov"])
    }

    func testErrors() {
        XCTAssertThrowsError(try FilterParser.parse(">abc"))
        XCTAssertThrowsError(try FilterParser.parse(">10parsecs"))
        XCTAssertThrowsError(try FilterParser.parse("modified>10mb"))
        XCTAssertThrowsError(try FilterParser.parse(":tag:purple"))
        XCTAssertThrowsError(try FilterParser.parse(":wat:x"))
        XCTAssertThrowsError(try FilterParser.parse("|"))
    }
}

final class LayoutTests: XCTestCase {
    func testSquarifyFillsTheRect() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let areas: [Double] = [6, 6, 4, 3, 2, 2, 1].map { $0 * 240_000 / 24 }
        let rects = TreemapLayout.squarify(areas: areas, in: rect)
        XCTAssertEqual(rects.count, areas.count)
        let total = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(total, 240_000, accuracy: 1)
        for (r, a) in zip(rects, areas) {
            XCTAssertEqual(Double(r.width * r.height), a, accuracy: 1)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        // No overlaps.
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let x = rects[i].intersection(rects[j])
                XCTAssertTrue(x.isNull || x.width * x.height < 0.5, "\(i) overlaps \(j)")
            }
        }
    }

    func testSquarifyAspectIsReasonable() {
        let rects = TreemapLayout.squarify(areas: Array(repeating: 100, count: 16), in: CGRect(x: 0, y: 0, width: 40, height: 40))
        for r in rects {
            XCTAssertLessThan(max(r.width / r.height, r.height / r.width), 2.01)
        }
    }

    func testNestedLayoutRespectsDetailAndExpansion() {
        let deep = FileNode.makeFile("deep.bin", logical: 1000)
        let c = FileNode.makeFolder("c", [deep])
        let b = FileNode.makeFolder("b", [c])
        let a = FileNode.makeFolder("a", [b])
        let root = FileNode.makeFolder("/r", [a, FileNode.makeFile("x", logical: 1000)])

        var p = LayoutParams()
        p.detailLevel = 1
        let items = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 800, height: 600), params: p) { $0.diskSize }
        XCTAssertTrue(items.contains { $0.node === a })
        XCTAssertFalse(items.contains { $0.node === b })

        p.alwaysExpand = [ObjectIdentifier(a), ObjectIdentifier(b)]
        let items2 = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 800, height: 600), params: p) { $0.diskSize }
        XCTAssertTrue(items2.contains { $0.node === c })
        XCTAssertFalse(items2.contains { $0.node === deep })

        // Children sit inside their parent.
        for item in items2 where item.parent >= 0 {
            XCTAssertTrue(items2[item.parent].rect.insetBy(dx: -1, dy: -1).contains(item.rect))
        }
        // Hit test finds the deepest.
        let cItem = items2.first { $0.node === c }!
        let hit = TreemapLayout.hitTest(items2, CGPoint(x: cItem.rect.midX, y: cItem.rect.maxY - 2))
        XCTAssertTrue(items2[hit!].node === c)
    }

    func testTinyElementsAreDroppedButCounted() {
        var kids = [FileNode.makeFile("big", logical: 1_000_000)]
        for i in 0..<100 { kids.append(FileNode.makeFile("t\(i)", logical: 1)) }
        let root = FileNode.makeFolder("/r", kids)
        let items = TreemapLayout.layout(root: root, in: CGRect(x: 0, y: 0, width: 300, height: 200), params: LayoutParams()) { $0.diskSize }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(root.fileCount, 101)
    }
}

final class ExportTests: XCTestCase {
    func sample() -> FileNode {
        FileNode.makeFolder("/data", [
            FileNode.makeFolder("docs", [FileNode.makeFile("a.txt", logical: 10), FileNode.makeFile("b.txt", logical: 30)]),
            FileNode.makeFile("c.bin", logical: 20),
        ])
    }

    func testTagsAndCommands() throws {
        let root = sample()
        let file = root.children[0].children[0]
        var ctx = ExportContext(node: file, nesting: 2)
        ctx.decimal = true
        XCTAssertEqual(try ExportScript("<%pathfile%>|<%file%>|<%fileext%>|<%sizebytes%>").render(ctx), "/data/docs/a.txt|a|txt|10")
        XCTAssertEqual(try ExportScript("{leftpad{<%sizebytes%>}{0}{5}}").render(ctx), "00010")
        XCTAssertEqual(try ExportScript("{rightpad{abcdef}{.}{3}}").render(ctx), "abc")
        XCTAssertEqual(try ExportScript("{leftpad{abcdef}{.}{3}}").render(ctx), "def")
        XCTAssertEqual(try ExportScript("{nest{--}}x").render(ctx), "----x")
        XCTAssertEqual(try ExportScript("{if{<%sizebytes%>}>{9}?{big}:{small}}").render(ctx), "big")
        XCTAssertEqual(try ExportScript("{if{<%isfile%>}!={true}?{folder}}").render(ctx), "")
        XCTAssertEqual(try ExportScript("{&curlyop}{&tab}{&curlycl}").render(ctx), "{\t}")
        XCTAssertEqual(try ExportScript("{script}\n\ta\n\tb{&br}").render(ctx), "ab\n")
    }

    func testParseErrors() {
        XCTAssertThrowsError(try ExportScript("{nope{x}}"))
        XCTAssertThrowsError(try ExportScript("{if{a}~{b}?{c}}"))
        XCTAssertThrowsError(try ExportScript("<%size"))
        XCTAssertThrowsError(try ExportScript("{leftpad{a}"))
        XCTAssertEqual(try ExportScript("<%bogus%>").warnings.count, 1)
    }

    func testRunnerOrderAndCounters() throws {
        let config = ExportConfig(name: "t", blockSort: .filesFirst, fineSort: .size, descending: true,
                                  header: "H{&br}", detail: "<%count%>:<%localcount%>:<%filename%>{&br}", footer: "F")
        let out = try ExportRunner.string(config: config, root: sample())
        XCTAssertEqual(out, "H\n0:0:data\n1:0:c.bin\n2:1:docs\n3:0:b.txt\n4:1:a.txt\nF")
    }

    func testBuiltInsCompile() throws {
        for c in ExportConfig.builtIns where !c.isSnapshot {
            _ = try ExportRunner.string(config: c, root: sample())
        }
    }

    func testPreviewLimit() throws {
        let config = ExportConfig(name: "t", detail: "x")
        XCTAssertEqual(try ExportRunner.string(config: config, root: sample(), limit: 2), "xx")
    }
}

final class SnapshotTests: XCTestCase {
    func testRoundTrip() throws {
        let f = FileNode.makeFile("späße 🎉.txt", logical: 1234, disk: 4096, modified: 1_600_000_000)
        f.tag = .blue
        f.setAttributes([.hidden, .compressed])
        let root = FileNode.makeFolder("/Volumes/X", [FileNode.makeFolder("sub", [f]), FileNode.makeFile("b", logical: 7)])
        let vol = VolumeInfo(name: "X", total: 1000, free: 400, isVolumeRoot: true)
        let data = SnapshotIO.encode(root: root, rootPath: "/Volumes/X", volume: vol)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tessera")
        defer { try? FileManager.default.removeItem(at: url) }
        try SnapshotIO.write(payload: data, to: url)
        let loaded = try SnapshotIO.read(url: url)
        XCTAssertEqual(loaded.root.name, "/Volumes/X")
        XCTAssertEqual(loaded.volume, vol)
        XCTAssertEqual(loaded.root.logicalSize, 1241)
        XCTAssertEqual(loaded.root.diskSize, 4096 + 7)
        let g = loaded.root.children[0].children[0]
        XCTAssertEqual(g.name, "späße 🎉.txt")
        XCTAssertEqual(g.tag, .blue)
        XCTAssertEqual(g.attributes, [.hidden, .compressed])
        XCTAssertEqual(g.modified, 1_600_000_000)
        XCTAssertEqual(g.path, "/Volumes/X/sub/späße 🎉.txt")
    }

    func testRejectsOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello world".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SnapshotIO.read(url: url))
    }

    func testDuImport() throws {
        let text = "8\t./a/x.bin\n4\t./a/y.bin\n12\t./a\n20\t./b\n40\t.\n"
        let root = try DuImporter.read(text: text)
        XCTAssertEqual(root.diskSize, 40 * 1024)
        let a = root.children.first { $0.name == "a" }!
        XCTAssertEqual(a.children.count, 2)
        XCTAssertTrue(root.children.contains { $0.name == "b" && $0.isFile })
        XCTAssertTrue(root.children.contains { $0.name == "(files)" && $0.diskSize == 8 * 1024 })
    }
}

final class CommandLineTests: XCTestCase {
    func testParse() throws {
        let c = try LaunchCommands.parse(["-NSDocumentRevisionsDebugMode", "YES", "scan", "/a;/b", "filter", "*.jpg",
                                          "export", "Files as CSV", "/tmp/o.csv", "load", "/s.tessera", "autoclose"])
        XCTAssertEqual(c.jobs.count, 3)
        XCTAssertEqual(c.jobs[0].source, .scan("/a"))
        XCTAssertEqual(c.jobs[1].filter, "*.jpg")
        XCTAssertEqual(c.jobs[1].exports, [.init(config: "Files as CSV", path: "/tmp/o.csv")])
        XCTAssertEqual(c.jobs[2].source, .load("/s.tessera"))
        XCTAssertNil(c.jobs[2].filter)
        XCTAssertTrue(c.autoclose)
    }

    func testErrors() {
        XCTAssertThrowsError(try LaunchCommands.parse(["filter", "*.jpg"]))
        XCTAssertThrowsError(try LaunchCommands.parse(["scan"]))
        XCTAssertThrowsError(try LaunchCommands.parse(["frobnicate"]))
    }
}

final class FormatTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(Format.size(0), "0 bytes")
        XCTAssertEqual(Format.size(1), "1 byte")
        XCTAssertEqual(Format.size(1500), "1.50 KB")
        XCTAssertEqual(Format.size(1_234_567_890), "1.23 GB")
        XCTAssertEqual(Format.size(1024, decimal: false), "1.00 KB")
    }

    func testAges() {
        XCTAssertEqual(Format.age(seconds: 30), "just now")
        XCTAssertEqual(Format.age(seconds: 3 * 86400), "3 days")
        XCTAssertEqual(Format.age(seconds: 31_557_600 + 2_629_800 * 3 + 10), "1 year 3 months")
    }
}

@MainActor
final class ScanSessionTests: XCTestCase {
    func makeTree() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tessera-test-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("c"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: base.appendingPathComponent("a/one.bin"))
        try Data(count: 20_000).write(to: base.appendingPathComponent("a/b/two.jpg"))
        try Data(count: 5_000).write(to: base.appendingPathComponent("c/three.txt"))
        try Data(count: 1).write(to: base.appendingPathComponent(".hidden"))
        return base
    }

    func waitUntilDone(_ s: ScanSession, timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while s.isScanning && Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testScanFilterAndRescan() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let s = ScanSession(path: base.path, watchChanges: false)
        defer { s.close() }
        var finished = false
        s.onFinished = { finished = true }
        s.startMasterScan()
        waitUntilDone(s)
        XCTAssertTrue(finished)
        XCTAssertEqual(s.root.logicalSize, 35_001)
        XCTAssertEqual(s.root.fileCount, 4)
        XCTAssertGreaterThanOrEqual(s.root.diskSize, 35_001)

        let a = s.root.children.first { $0.name == "a" }!
        XCTAssertEqual(a.logicalSize, 30_000)

        // Filter during/after scan.
        s.sizeMetric = .logical
        s.setFilter(try FilterParser.parse("*.jpg"))
        XCTAssertEqual(s.root.filteredSize, 20_000)
        XCTAssertEqual(s.weight(a), 20_000)

        // Tags survive a rescan and drive filters.
        let c = s.root.children.first { $0.name == "c" }!
        s.toggleTag(.red, on: c)
        s.setFilter(try FilterParser.parse(":red"))
        XCTAssertEqual(s.root.filteredSize, 5_000)

        try Data(count: 7_000).write(to: base.appendingPathComponent("c/four.txt"))
        try FileManager.default.removeItem(at: base.appendingPathComponent("a/one.bin"))
        s.startMasterScan()
        waitUntilDone(s)
        XCTAssertEqual(c.tag, .red)
        XCTAssertTrue(s.root.children.contains { $0 === c })
        XCTAssertEqual(s.root.logicalSize, 32_001)
        XCTAssertEqual(s.root.filteredSize, 12_000)
        XCTAssertEqual(a.logicalSize, 20_000)
        XCTAssertGreaterThan(c.children.first { $0.name == "four.txt" }!.changedAt, 0)
    }

    func testStop() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let s = ScanSession(path: base.path, watchChanges: false)
        defer { s.close() }
        s.startMasterScan()
        s.stopScan()
        XCTAssertFalse(s.isScanning)
    }
}
