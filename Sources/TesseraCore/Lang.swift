import Foundation

/// Interface language. Strings live next to each other in code as tr("English", "Русский"),
/// so the app needs no .lproj resources (it builds with the Command Line Tools alone).
public enum Lang {
    public enum Code: String, Codable, CaseIterable {
        case en, ru
    }

    /// Set by the app from its settings. Read everywhere text is made.
    public static var current: Code = .en

    /// The language macOS is set to, if we have it.
    public static var system: Code {
        let first = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return first.hasPrefix("ru") ? .ru : .en
    }

    public static var locale: Locale {
        Locale(identifier: current == .ru ? "ru_RU" : "en_US")
    }
}

/// Picks the text for the current language.
@inline(__always)
public func tr(_ en: String, _ ru: String) -> String {
    Lang.current == .ru ? ru : en
}

/// Russian plural forms: 1 файл, 2 файла, 5 файлов.
public func ruPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

/// "3 files" / "3 файла".
public func countText(_ n: Int, en one: String, _ enMany: String, ru: (String, String, String)) -> String {
    if Lang.current == .ru {
        return "\(Format.count(n)) \(ruPlural(n, ru.0, ru.1, ru.2))"
    }
    return "\(Format.count(n)) \(n == 1 ? one : enMany)"
}
