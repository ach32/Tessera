import Foundation

public struct ExportConfig: Codable, Equatable, Identifiable {
    public enum BlockSort: String, Codable, CaseIterable {
        case foldersFirst, filesFirst, mixed
        public var label: String {
            switch self {
            case .foldersFirst: return tr("Folders first", "Сначала папки")
            case .filesFirst: return tr("Files first", "Сначала файлы")
            case .mixed: return tr("Don't care", "Неважно")
            }
        }
    }
    public enum FineSort: String, Codable, CaseIterable {
        case none, name, size, modified
        public var label: String {
            switch self {
            case .none: return tr("Don't care", "Неважно")
            case .name: return tr("Name", "Имя")
            case .size: return tr("Size", "Размер")
            case .modified: return tr("Date modified", "Дата изменения")
            }
        }
    }

    public var id: UUID
    public var name: String
    public var fileName: String
    public var fileExtension: String
    public var blockSort: BlockSort
    public var fineSort: FineSort
    public var descending: Bool
    public var header: String
    public var detail: String
    public var footer: String
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, fileName: String = "report", fileExtension: String = "txt",
                blockSort: BlockSort = .foldersFirst, fineSort: FineSort = .size, descending: Bool = true,
                header: String = "", detail: String = "", footer: String = "", isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.blockSort = blockSort
        self.fineSort = fineSort
        self.descending = descending
        self.header = header
        self.detail = detail
        self.footer = footer
        self.isBuiltIn = isBuiltIn
    }

    public var isSnapshot: Bool { id == ExportConfig.snapshotID }

    public static let snapshotID = UUID(uuidString: "7E55E7A0-0000-4000-8000-000000000001")!

    public static var snapshot: ExportConfig { ExportConfig(
        id: snapshotID, name: tr("Tessera snapshot (reload later)", "Снимок Tessera (можно открыть позже)"), fileName: "scan",
        fileExtension: SnapshotIO.fileExtension, isBuiltIn: true) }

    public static var builtIns: [ExportConfig] { [
        snapshot,
        ExportConfig(
            id: UUID(uuidString: "7E55E7A0-0000-4000-8000-000000000002")!,
            name: tr("Files as CSV", "Файлы в CSV"), fileName: "files", fileExtension: "csv",
            blockSort: .filesFirst, fineSort: .size, descending: true,
            header: "path,name,size_bytes,disk_bytes,modified{&br}",
            detail: "{if{<%isfile%>}=={true}?{\"<%pathfile%>\",\"<%filename%>\",<%sizebytes%>,<%disksizebytes%>,<%filemodifydate%> <%filemodifytime%>{&br}}}",
            isBuiltIn: true),
        ExportConfig(
            id: UUID(uuidString: "7E55E7A0-0000-4000-8000-000000000003")!,
            name: tr("Outline", "Дерево"), fileName: "outline", fileExtension: "txt",
            blockSort: .foldersFirst, fineSort: .size, descending: true,
            header: tr("<%pathfile%>  (<%disksize%> on disk, <%itemcount%> files){&br}{&br}", "<%pathfile%>  (<%disksize%> на диске, файлов: <%itemcount%>){&br}{&br}"),
            detail: "{if{<%nestinglevel%>}>{0}?{{nest{    }}<%filename%>{if{<%iscontainer%>}=={true}?{/}}{&tab}<%disksize%>{&br}}}",
            isBuiltIn: true),
        ExportConfig(
            id: UUID(uuidString: "7E55E7A0-0000-4000-8000-000000000004")!,
            name: tr("Grouped by folder", "По папкам"), fileName: "by-folder", fileExtension: "txt",
            blockSort: .filesFirst, fineSort: .size, descending: true,
            header: tr("Contents of <%pathfile%>{&br}", "Содержимое <%pathfile%>{&br}"),
            detail: "{if{<%iscontainer%>}=={true}?{{&br}<%pathfile%>  [<%disksize%>]{&br}}:{{&tab}{leftpad{<%disksize%>}{ }{10}}  <%filename%>{&br}}}",
            footer: tr("{&br}End of report.{&br}", "{&br}Конец отчёта.{&br}"),
            isBuiltIn: true),
    ] }
}

public enum ExportRunner {
    private struct Stop: Error {}

    /// Renders `config` over `root` and what `include` lets through. Calls `emit` with chunks.
    /// `limit` caps how many elements are rendered (for the preview).
    public static func run(config: ExportConfig,
                           root: FileNode,
                           include: @escaping (FileNode) -> Bool,
                           sizes: ((FileNode) -> (Int64, Int64))? = nil,
                           decimal: Bool = true,
                           limit: Int? = nil,
                           emit: @escaping (String) -> Void) throws {
        let header = try ExportScript(config.header)
        let detail = try ExportScript(config.detail)
        let footer = try ExportScript(config.footer)
        let now = Date().timeIntervalSince1970

        func context(_ n: FileNode, _ nesting: Int) -> ExportContext {
            var c = ExportContext(node: n, nesting: nesting)
            c.decimal = decimal
            c.now = now
            if let sizes {
                let s = sizes(n)
                c.visibleLogical = s.0
                c.visibleDisk = s.1
            }
            return c
        }

        emit(header.render(context(root, 0)))

        var count = 0, files = 0, folders = 0, containers = 0
        var buffer = ""

        func sortChildren(_ list: [FileNode]) -> [FileNode] {
            var l = list
            let desc = config.descending
            func fine(_ a: FileNode, _ b: FileNode) -> Bool {
                switch config.fineSort {
                case .none: return false
                case .name:
                    let r = a.name.localizedStandardCompare(b.name)
                    return desc ? r == .orderedDescending : r == .orderedAscending
                case .size:
                    let x = sizes?(a).1 ?? a.diskSize, y = sizes?(b).1 ?? b.diskSize
                    return desc ? x > y : x < y
                case .modified:
                    return desc ? a.modified > b.modified : a.modified < b.modified
                }
            }
            func block(_ n: FileNode) -> Int {
                switch config.blockSort {
                case .foldersFirst: return n.isContainer ? 0 : 1
                case .filesFirst: return n.isContainer ? 1 : 0
                case .mixed: return 0
                }
            }
            if config.blockSort == .mixed && config.fineSort == .none { return l }
            l.sort { a, b in
                let ba = block(a), bb = block(b)
                if ba != bb { return ba < bb }
                return fine(a, b)
            }
            return l
        }

        func visit(_ n: FileNode, _ nesting: Int, _ local: inout (Int, Int, Int, Int)) throws {
            if let limit, count >= limit { throw Stop() }
            var c = context(n, nesting)
            c.count = count
            c.fileCount = files
            c.folderCount = folders
            c.containerCount = containers
            c.localCount = local.0
            c.localFileCount = local.1
            c.localFolderCount = local.2
            c.localContainerCount = local.3
            buffer += detail.render(c)
            if buffer.utf8.count > 64 * 1024 {
                emit(buffer)
                buffer = ""
            }
            count += 1
            local.0 += 1
            if n.isFile {
                files += 1
                local.1 += 1
            } else if n.isContainer {
                folders += 1
                containers += 1
                local.2 += 1
                local.3 += 1
                var inner = (0, 0, 0, 0)
                for child in sortChildren(n.children.filter(include)) {
                    try visit(child, nesting + 1, &inner)
                }
            }
        }

        var top = (0, 0, 0, 0)
        do {
            try visit(root, 0, &top)
        } catch is Stop {
            // preview limit reached
        }
        if !buffer.isEmpty { emit(buffer) }
        emit(footer.render(context(root, 0)))
    }

    /// Convenience for previews and tests.
    public static func string(config: ExportConfig, root: FileNode, include: @escaping (FileNode) -> Bool = { _ in true },
                              decimal: Bool = true, limit: Int? = nil) throws -> String {
        var out = ""
        try run(config: config, root: root, include: include, decimal: decimal, limit: limit) { out += $0 }
        return out
    }
}
