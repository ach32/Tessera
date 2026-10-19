import Foundation

/// The text export mini-language.
///   <%name%>                     a value of the current element (see `ExportScript.tags`)
///   {&br} {&tab} {&curlyop} {&curlycl} {&angleop} {&anglecl}
///   {leftpad{text}{pad}{len}}    {rightpad{text}{pad}{len}}    {nest{text}}
///   {upper{text}} {lower{text}}
///   {if{a}==|!=|<|<=|>|>={b}?{then}:{else}}   numbers compare as numbers, otherwise as text
///   {script}                     from here on, typed tabs and newlines are not output
public struct ExportScript {
    indirect enum Node {
        case text(String)
        case tag(String)
        case command(String, [[Node]])
        case cond([Node], String, [Node], [Node], [Node]?)
    }

    let nodes: [Node]
    public let warnings: [String]

    public static let tags: [String] = [
        "pathfile", "path", "file", "filename", "fileext", "name",
        "size", "sizebytes", "disksize", "disksizebytes",
        "filecreatedate", "filemodifydate", "fileaccessdate",
        "filecreatetime", "filemodifytime", "fileaccesstime",
        "filecreateage", "filemodifyage", "fileaccessage",
        "isfile", "isfolder", "iscontainer", "containsfiles", "containsfolders", "containscontainers",
        "nestinglevel", "childcount", "itemcount", "tag",
        "count", "localcount", "filecount", "localfilecount",
        "foldercount", "localfoldercount", "containercount", "localcontainercount",
    ]
    public static let commands: [String] = [
        "{&br}", "{&tab}", "{&curlyop}", "{&curlycl}", "{&angleop}", "{&anglecl}",
        "{leftpad{text}{pad}{length}}", "{rightpad{text}{pad}{length}}", "{nest{text}}",
        "{upper{text}}", "{lower{text}}", "{if{a}=={b}?{then}:{else}}", "{script}",
    ]

    public init(_ source: String) throws {
        var p = Parser(Array(source))
        nodes = try p.parseSequence(untilClose: false)
        warnings = p.warnings
    }

    public func render(_ ctx: ExportContext) -> String {
        var out = ""
        ExportScript.render(nodes, ctx, &out)
        return out
    }

    private static func render(_ nodes: [Node], _ ctx: ExportContext, _ out: inout String) {
        for n in nodes {
            switch n {
            case .text(let s):
                out += s
            case .tag(let name):
                out += ctx.value(of: name)
            case .command(let name, let args):
                let a = args.map { arg -> String in var s = ""; render(arg, ctx, &s); return s }
                out += apply(name, a, ctx)
            case .cond(let lhs, let op, let rhs, let then, let els):
                var l = "", r = ""
                render(lhs, ctx, &l)
                render(rhs, ctx, &r)
                if compare(l.trimmingCharacters(in: .whitespaces), op, r.trimmingCharacters(in: .whitespaces)) {
                    render(then, ctx, &out)
                } else if let els {
                    render(els, ctx, &out)
                }
            }
        }
    }

    private static func apply(_ name: String, _ a: [String], _ ctx: ExportContext) -> String {
        switch name {
        case "&br": return "\n"
        case "&tab": return "\t"
        case "&curlyop": return "{"
        case "&curlycl": return "}"
        case "&angleop": return "<"
        case "&anglecl": return ">"
        case "leftpad", "rightpad":
            guard a.count == 3, let len = Int(a[2].trimmingCharacters(in: .whitespaces)), len >= 0 else { return a.first ?? "" }
            return pad(a[0], with: a[1], to: len, left: name == "leftpad")
        case "nest":
            return String(repeating: a.first ?? "", count: max(0, ctx.nesting))
        case "upper": return (a.first ?? "").uppercased()
        case "lower": return (a.first ?? "").lowercased()
        default: return ""
        }
    }

    /// Pads to `length`; text longer than that is cut from the padded side's opposite end
    /// (leftpad keeps the right end, rightpad keeps the left end).
    static func pad(_ text: String, with padText: String, to length: Int, left: Bool) -> String {
        let chars = Array(text)
        if chars.count >= length {
            return left ? String(chars.suffix(length)) : String(chars.prefix(length))
        }
        let fill = padText.isEmpty ? " " : padText
        var padding = ""
        while padding.count < length - chars.count { padding += fill }
        padding = String(padding.prefix(length - chars.count))
        return left ? padding + text : text + padding
    }

    static func compare(_ a: String, _ op: String, _ b: String) -> Bool {
        if let x = Double(a), let y = Double(b) {
            switch op {
            case "==": return x == y
            case "!=": return x != y
            case "<": return x < y
            case "<=": return x <= y
            case ">": return x > y
            case ">=": return x >= y
            default: return false
            }
        }
        switch op {
        case "==": return a == b
        case "!=": return a != b
        case "<": return a < b
        case "<=": return a <= b
        case ">": return a > b
        case ">=": return a >= b
        default: return false
        }
    }

    // MARK: Parser

    struct Parser {
        let c: [Character]
        var i = 0
        var scriptMode = false
        var warnings: [String] = []

        init(_ c: [Character]) { self.c = c }

        func peek(_ s: String) -> Bool {
            let chars = Array(s)
            guard i + chars.count <= c.count else { return false }
            for k in 0..<chars.count where c[i + k] != chars[k] { return false }
            return true
        }

        mutating func skipLayout() {
            while i < c.count, c[i] == " " || c[i] == "\t" || c[i] == "\n" || c[i] == "\r" { i += 1 }
        }

        mutating func parseSequence(untilClose: Bool) throws -> [Node] {
            var nodes: [Node] = []
            var text = ""
            func flush() {
                if !text.isEmpty { nodes.append(.text(text)); text = "" }
            }
            while i < c.count {
                let ch = c[i]
                if ch == "}" {
                    if untilClose { flush(); return nodes }
                    throw FilterError(message: tr("Unmatched } at position \(i + 1).", "Лишняя } в позиции \(i + 1)."))
                }
                if peek("<%") {
                    flush()
                    i += 2
                    var name = ""
                    while i < c.count && !peek("%>") { name.append(c[i]); i += 1 }
                    guard peek("%>") else { throw FilterError(message: tr("A <% is never closed with %>.", "<% не закрыт с помощью %>.")) }
                    i += 2
                    let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                    if !ExportScript.tags.contains(key) { warnings.append("Unknown tag <%\(key)%>") }
                    nodes.append(.tag(key))
                    continue
                }
                if ch == "{" {
                    flush()
                    i += 1
                    if let node = try parseCommand() { nodes.append(node) }
                    continue
                }
                if scriptMode && (ch == "\n" || ch == "\t" || ch == "\r") {
                    i += 1
                    continue
                }
                text.append(ch)
                i += 1
            }
            if untilClose { throw FilterError(message: tr("A { is never closed with }.", "{ не закрыта с помощью }.")) }
            flush()
            return nodes
        }

        /// After "{". Returns nil for {script}.
        mutating func parseCommand() throws -> Node? {
            var name = ""
            while i < c.count, c[i] != "{" && c[i] != "}" { name.append(c[i]); i += 1 }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if name == "script" {
                try expect("}")
                scriptMode = true
                return nil
            }
            if name == "if" {
                let lhs = try group()
                skipLayout()
                var op = ""
                while i < c.count, "=!<>".contains(c[i]) { op.append(c[i]); i += 1 }
                guard ["==", "!=", "<", "<=", ">", ">="].contains(op) else {
                    throw FilterError(message: tr("{if} needs ==, !=, <, <=, > or >= between its two values.", "{if} требует ==, !=, <, <=, > или >= между двумя значениями."))
                }
                let rhs = try group()
                skipLayout()
                try expect("?")
                let then = try group()
                skipLayout()
                var els: [Node]?
                if i < c.count && c[i] == ":" {
                    i += 1
                    els = try group()
                    skipLayout()
                }
                try expect("}")
                return .cond(lhs, op, rhs, then, els)
            }
            var args: [[Node]] = []
            skipLayout()
            while i < c.count && c[i] == "{" {
                args.append(try group())
                skipLayout()
            }
            try expect("}")
            let known = ["&br", "&tab", "&curlyop", "&curlycl", "&angleop", "&anglecl",
                         "leftpad", "rightpad", "nest", "upper", "lower"]
            guard known.contains(name) else { throw FilterError(message: tr("Unknown command {\(name)}.", "Неизвестная команда {\(name)}.")) }
            return .command(name, args)
        }

        /// "{...}" with the braces.
        mutating func group() throws -> [Node] {
            skipLayout()
            try expect("{")
            let nodes = try parseSequence(untilClose: true)
            guard i < c.count, c[i] == "}" else { throw FilterError(message: tr("A { is never closed with }.", "{ не закрыта с помощью }.")) }
            i += 1
            return nodes
        }

        mutating func expect(_ ch: Character) throws {
            skipLayoutIfScript()
            guard i < c.count, c[i] == ch else {
                throw FilterError(message: tr("Expected “\(ch)” at position \(i + 1).", "Ожидался «\(ch)» в позиции \(i + 1)."))
            }
            i += 1
        }

        mutating func skipLayoutIfScript() {
            if scriptMode { skipLayout() }
        }
    }
}

/// The element being rendered and its counters.
public struct ExportContext {
    public var node: FileNode
    public var nesting: Int
    public var count = 0, localCount = 0
    public var fileCount = 0, localFileCount = 0
    public var folderCount = 0, localFolderCount = 0
    public var containerCount = 0, localContainerCount = 0
    public var decimal = true
    public var now = Date().timeIntervalSince1970
    /// Visible size of the element (filtered when a filter is on).
    public var visibleLogical: Int64?
    public var visibleDisk: Int64?

    public init(node: FileNode, nesting: Int) {
        self.node = node
        self.nesting = nesting
    }

    public func value(of tag: String) -> String {
        let n = node
        let full = n.path
        let logical = visibleLogical ?? n.logicalSize
        let disk = visibleDisk ?? n.diskSize
        switch tag {
        case "pathfile": return full
        case "path":
            if n.parent == nil { return (full as NSString).deletingLastPathComponent }
            return n.parent!.path
        case "file": return n.isFile ? (n.name as NSString).deletingPathExtension : n.name
        case "filename", "name": return n.parent == nil ? n.displayName : n.name
        case "fileext": return n.isFile ? (n.name as NSString).pathExtension : ""
        case "size": return Format.size(logical, decimal: decimal)
        case "sizebytes": return String(logical)
        case "disksize": return Format.size(disk, decimal: decimal)
        case "disksizebytes": return String(disk)
        case "filecreatedate": return Format.dateOnly(n.created)
        case "filemodifydate": return Format.dateOnly(n.modified)
        case "fileaccessdate": return Format.dateOnly(n.accessed)
        case "filecreatetime": return Format.timeOnly(n.created)
        case "filemodifytime": return Format.timeOnly(n.modified)
        case "fileaccesstime": return Format.timeOnly(n.accessed)
        case "filecreateage": return n.created > 0 ? Format.age(seconds: now - n.created) : ""
        case "filemodifyage": return n.modified > 0 ? Format.age(seconds: now - n.modified) : ""
        case "fileaccessage": return n.accessed > 0 ? Format.age(seconds: now - n.accessed) : ""
        case "isfile": return n.isFile ? "true" : "false"
        case "isfolder": return (n.kind == .folder || n.kind == .mountPoint) ? "true" : "false"
        case "iscontainer": return n.isContainer ? "true" : "false"
        case "containsfiles": return n.containsFiles ? "true" : "false"
        case "containsfolders", "containscontainers": return n.containsFolders ? "true" : "false"
        case "nestinglevel": return String(nesting)
        case "childcount": return String(n.children.count)
        case "itemcount": return String(n.fileCount)
        case "tag": return n.tag.key
        case "count": return String(count)
        case "localcount": return String(localCount)
        case "filecount": return String(fileCount)
        case "localfilecount": return String(localFileCount)
        case "foldercount": return String(folderCount)
        case "localfoldercount": return String(localFolderCount)
        case "containercount": return String(containerCount)
        case "localcontainercount": return String(localContainerCount)
        default: return ""
        }
    }
}
