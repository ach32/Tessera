import Foundation

/// Command line:
///   Tessera scan <path[;path]> [filter <filter>] [export <config name> <file>]...
///           load <snapshot[;snapshot]> [filter ...] [export ...]
///           autoclose      quit after all exports finished
///           help
/// filter / export apply to the scan or load before them.
public struct LaunchCommands: Equatable {
    public enum Source: Equatable {
        case scan(String)
        case load(String)
    }
    public struct Export: Equatable {
        public var config: String
        public var path: String
    }
    public struct Job: Equatable {
        public var source: Source
        public var filter: String?
        public var exports: [Export] = []
    }

    public var jobs: [Job] = []
    public var autoclose = false
    public var help = false

    public var isEmpty: Bool { jobs.isEmpty && !help }

    public static var helpText: String { Lang.current == .ru ? helpTextRu : helpTextEn }

    static let helpTextEn = """
    Tessera command line

      scan "<path>"              open a scan window on <path>. Several paths: separate with ;
                                 or repeat scan.
      load "<file>"              open a snapshot (.tessera) or du output (.du / .txt).
      filter "<filter>"          apply <filter> to the scan/load before it.
      export "<config>" "<file>" when the scans finish, export with the named export
                                 configuration (case sensitive) to <file>.
      autoclose                  quit when every export is done.
      help                       show this.

    Example:
      Tessera.app/Contents/MacOS/Tessera scan ~/Downloads filter "*.dmg;>100mb" export "Files as CSV" ~/big-dmgs.csv autoclose
    """

    static let helpTextRu = """
    Командная строка Tessera

      scan "<путь>"              открыть окно сканирования для <пути>. Несколько путей —
                                 через ; или несколько команд scan.
      load "<файл>"              открыть снимок (.tessera) или вывод du (.du / .txt).
      filter "<фильтр>"          применить <фильтр> к предыдущему scan/load.
      export "<формат>" "<файл>" когда сканирование закончится, экспортировать в <файл>
                                 в формате с этим именем (регистр важен).
      autoclose                  выйти, когда все экспорты готовы.
      help                       показать эту справку.

    Пример:
      Tessera.app/Contents/MacOS/Tessera scan ~/Downloads filter "*.dmg;>100mb" export "Files as CSV" ~/big-dmgs.csv autoclose
    """

    public static func parse(_ arguments: [String]) throws -> LaunchCommands {
        var out = LaunchCommands()
        var args: [String] = []
        // Drop what macOS and Xcode add: -psn_..., -NSSomething VALUE, -AppleSomething VALUE.
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a.hasPrefix("-psn_") { i += 1; continue }
            if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 2; continue }
            args.append(a)
            i += 1
        }

        var lastGroup: [Int] = []   // indices of the jobs the next filter/export attaches to
        i = 0
        func value(_ what: String) throws -> String {
            guard i + 1 < args.count else { throw FilterError(message: tr("“\(what)” needs a value.", "«\(what)» требует значение.")) }
            i += 1
            return args[i]
        }
        while i < args.count {
            let word = args[i].lowercased()
            switch word {
            case "scan", "load":
                let v = try value(word)
                lastGroup = []
                for p in v.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
                    let path = (p as NSString).expandingTildeInPath
                    out.jobs.append(Job(source: word == "scan" ? .scan(path) : .load(path)))
                    lastGroup.append(out.jobs.count - 1)
                }
            case "filter":
                let v = try value(word)
                guard !lastGroup.isEmpty else { throw FilterError(message: tr("“filter” must follow a scan or load.", "«filter» должен идти после scan или load.")) }
                for j in lastGroup { out.jobs[j].filter = v }
            case "export":
                let name = try value(word)
                let path = try value(word)
                guard !lastGroup.isEmpty else { throw FilterError(message: tr("“export” must follow a scan or load.", "«export» должен идти после scan или load.")) }
                for j in lastGroup {
                    out.jobs[j].exports.append(Export(config: name, path: (path as NSString).expandingTildeInPath))
                }
            case "autoclose":
                out.autoclose = true
            case "help", "-h", "--help", "-help":
                out.help = true
            default:
                throw FilterError(message: tr("Unknown command “\(args[i])”. Try: help", "Неизвестная команда «\(args[i])». Попробуйте: help"))
            }
            i += 1
        }
        return out
    }
}
