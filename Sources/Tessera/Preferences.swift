import AppKit
import TesseraCore

enum ViewStyle: String, Codable, CaseIterable {
    case flat, classes
}

enum LanguageChoice: String, Codable, CaseIterable {
    case system, en, ru

    var resolved: Lang.Code {
        switch self {
        case .system: return Lang.system
        case .en: return .en
        case .ru: return .ru
        }
    }
}

struct AppSettings: Codable, Equatable {
    var language: LanguageChoice = .system
    // Geometry
    var fontSize: Double = 11
    var minElementSize: Double = 4
    var proportion: Double = 1
    var initialDetail: Int = 3
    var showFreeSpace: Bool = true
    var showUnknownSpace: Bool = false
    var sortItems: Bool = true
    // Animation
    var zoomDuration: Double = 0.25
    var smoothness: Double = 20
    var dynaSmooth: Bool = true
    // Behavior
    var sizeMetric: SizeMetric = .disk
    var decimalUnits: Bool = true
    var watchChanges: Bool = true
    var crossMountPoints: Bool = false
    var bounceWhenDone: Bool = true
    var keepTooltipOnMove: Bool = true
    var tooltipDates: Bool = true
    var tooltipAges: Bool = true
    var popupLog: Bool = true
    var logWarnings: Bool = true
    var confirmTrash: Bool = true
    // Look
    var levelContrast: Double = 0.5
    var borderContrast: Double = 0.5
    var haloLevels: Int = 1
    var hoverHighlight: Bool = true
    var dropShadow: Bool = true
    var mouseTrail: Bool = false
    // Styles
    var defaultStyle: ViewStyle = .flat
    var colors = FlatColors()
    var fileClasses: [FileClass] = FileClass.defaults
    // Export
    var exportConfigs: [ExportConfig] = []

    init() {}

    // Every key is optional so settings saved by an older build still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        language = try c.decodeIfPresent(LanguageChoice.self, forKey: .language) ?? d.language
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        minElementSize = try c.decodeIfPresent(Double.self, forKey: .minElementSize) ?? d.minElementSize
        proportion = try c.decodeIfPresent(Double.self, forKey: .proportion) ?? d.proportion
        initialDetail = try c.decodeIfPresent(Int.self, forKey: .initialDetail) ?? d.initialDetail
        showFreeSpace = try c.decodeIfPresent(Bool.self, forKey: .showFreeSpace) ?? d.showFreeSpace
        showUnknownSpace = try c.decodeIfPresent(Bool.self, forKey: .showUnknownSpace) ?? d.showUnknownSpace
        sortItems = try c.decodeIfPresent(Bool.self, forKey: .sortItems) ?? d.sortItems
        zoomDuration = try c.decodeIfPresent(Double.self, forKey: .zoomDuration) ?? d.zoomDuration
        smoothness = try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? d.smoothness
        dynaSmooth = try c.decodeIfPresent(Bool.self, forKey: .dynaSmooth) ?? d.dynaSmooth
        sizeMetric = try c.decodeIfPresent(SizeMetric.self, forKey: .sizeMetric) ?? d.sizeMetric
        decimalUnits = try c.decodeIfPresent(Bool.self, forKey: .decimalUnits) ?? d.decimalUnits
        watchChanges = try c.decodeIfPresent(Bool.self, forKey: .watchChanges) ?? d.watchChanges
        crossMountPoints = try c.decodeIfPresent(Bool.self, forKey: .crossMountPoints) ?? d.crossMountPoints
        bounceWhenDone = try c.decodeIfPresent(Bool.self, forKey: .bounceWhenDone) ?? d.bounceWhenDone
        keepTooltipOnMove = try c.decodeIfPresent(Bool.self, forKey: .keepTooltipOnMove) ?? d.keepTooltipOnMove
        tooltipDates = try c.decodeIfPresent(Bool.self, forKey: .tooltipDates) ?? d.tooltipDates
        tooltipAges = try c.decodeIfPresent(Bool.self, forKey: .tooltipAges) ?? d.tooltipAges
        popupLog = try c.decodeIfPresent(Bool.self, forKey: .popupLog) ?? d.popupLog
        logWarnings = try c.decodeIfPresent(Bool.self, forKey: .logWarnings) ?? d.logWarnings
        confirmTrash = try c.decodeIfPresent(Bool.self, forKey: .confirmTrash) ?? d.confirmTrash
        levelContrast = try c.decodeIfPresent(Double.self, forKey: .levelContrast) ?? d.levelContrast
        borderContrast = try c.decodeIfPresent(Double.self, forKey: .borderContrast) ?? d.borderContrast
        haloLevels = try c.decodeIfPresent(Int.self, forKey: .haloLevels) ?? d.haloLevels
        hoverHighlight = try c.decodeIfPresent(Bool.self, forKey: .hoverHighlight) ?? d.hoverHighlight
        dropShadow = try c.decodeIfPresent(Bool.self, forKey: .dropShadow) ?? d.dropShadow
        mouseTrail = try c.decodeIfPresent(Bool.self, forKey: .mouseTrail) ?? d.mouseTrail
        defaultStyle = try c.decodeIfPresent(ViewStyle.self, forKey: .defaultStyle) ?? d.defaultStyle
        colors = try c.decodeIfPresent(FlatColors.self, forKey: .colors) ?? d.colors
        fileClasses = try c.decodeIfPresent([FileClass].self, forKey: .fileClasses) ?? d.fileClasses
        exportConfigs = try c.decodeIfPresent([ExportConfig].self, forKey: .exportConfigs) ?? d.exportConfigs
    }
}

extension Notification.Name {
    static let tesseraSettingsChanged = Notification.Name("TesseraSettingsChanged")
}

/// The app's settings, saved in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private static let key = "settings.v1"

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.language != oldValue.language {
                Lang.current = settings.language.resolved
                FileClassNames.translate(&settings.fileClasses)
            }
            save()
            NotificationCenter.default.post(name: .tesseraSettingsChanged, object: nil)
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Preferences.key),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        Lang.current = settings.language.resolved
        FileClassNames.translate(&settings.fileClasses)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Preferences.key)
        }
    }

    var exportConfigs: [ExportConfig] { ExportConfig.builtIns + settings.exportConfigs }

    /// A configuration by name, also accepting a built-in's name in the other language
    /// (so command lines keep working whatever the interface language).
    func exportConfig(named name: String) -> ExportConfig? {
        if let c = exportConfigs.first(where: { $0.name == name }) { return c }
        let saved = Lang.current
        defer { Lang.current = saved }
        for code in Lang.Code.allCases {
            Lang.current = code
            if let c = ExportConfig.builtIns.first(where: { $0.name == name }) {
                Lang.current = saved
                return ExportConfig.builtIns.first { $0.id == c.id }
            }
        }
        return nil
    }

    func resetAll() { settings = AppSettings() }
}

/// The default file kinds have names in both languages; switching the language renames
/// the ones the user hasn't renamed.
enum FileClassNames {
    static let pairs: [(String, String)] = [
        ("Images", "Изображения"), ("Video", "Видео"), ("Audio", "Аудио"), ("Archives", "Архивы"),
        ("Disk images & installers", "Образы дисков и установщики"), ("Documents", "Документы"),
        ("Code & data", "Код и данные"), ("Logs & caches", "Логи и кэши"),
    ]

    static func translate(_ classes: inout [FileClass]) {
        for i in classes.indices {
            for (en, ru) in pairs where classes[i].name == en || classes[i].name == ru {
                classes[i].name = Lang.current == .ru ? ru : en
            }
        }
    }

    static func localizedDefaults() -> [FileClass] {
        var d = FileClass.defaults
        translate(&d)
        return d
    }
}
