import Foundation

public enum Format {
    /// "1.4 GB". Decimal units by default, like Finder; binary (1024) when asked.
    public static func size(_ bytes: Int64, decimal: Bool = true) -> String {
        let base: Double = decimal ? 1000 : 1024
        let units = Lang.current == .ru
            ? ["байт", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
            : ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(bytes)
        var u = 0
        while abs(v) >= base && u < units.count - 1 {
            v /= base
            u += 1
        }
        if u == 0 {
            if Lang.current == .ru { return "\(bytes) байт" }
            return bytes == 1 ? "1 byte" : "\(bytes) bytes"
        }
        let digits = v < 10 ? 2 : (v < 100 ? 1 : 0)
        var number = String(format: "%.\(digits)f", v)
        if Lang.current == .ru { number = number.replacingOccurrences(of: ".", with: ",") }
        return number + " " + units[u]
    }

    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Lang.locale
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "1 year 3 months", "5 days", "3 hours", "just now".
    public static func age(seconds: Double) -> String {
        let s = max(0, seconds)
        let minute = 60.0, hour = 3600.0, day = 86400.0, month = 2_629_800.0, year = 31_557_600.0
        let ru = Lang.current == .ru
        func plural(_ n: Int, _ w: String) -> String {
            guard ru else { return "\(n) \(w)\(n == 1 ? "" : "s")" }
            let forms: (String, String, String)
            switch w {
            case "year": forms = ("год", "года", "лет")
            case "month": forms = ("месяц", "месяца", "месяцев")
            case "day": forms = ("день", "дня", "дней")
            case "hour": forms = ("час", "часа", "часов")
            default: forms = ("минута", "минуты", "минут")
            }
            return "\(n) \(ruPlural(n, forms.0, forms.1, forms.2))"
        }
        if s >= year {
            let y = Int(s / year)
            let m = Int((s - Double(y) * year) / month)
            return m > 0 ? plural(y, "year") + " " + plural(m, "month") : plural(y, "year")
        }
        if s >= month {
            let m = Int(s / month)
            let d = Int((s - Double(m) * month) / day)
            return d > 0 ? plural(m, "month") + " " + plural(d, "day") : plural(m, "month")
        }
        if s >= day { return plural(Int(s / day), "day") }
        if s >= hour { return plural(Int(s / hour), "hour") }
        if s >= minute { return plural(Int(s / minute), "minute") }
        return ru ? "только что" : "just now"
    }

    /// "3 days ago" / "3 дня назад".
    public static func ago(seconds: Double) -> String {
        let a = age(seconds: seconds)
        if a == "just now" || a == "только что" { return a }
        return Lang.current == .ru ? a + " назад" : a + " ago"
    }

    public static func date(_ unix: Double) -> String {
        guard unix > 0 else { return "—" }
        dateFormatter.locale = Lang.locale
        return dateFormatter.string(from: Date(timeIntervalSince1970: unix))
    }

    public static func dateOnly(_ unix: Double) -> String {
        guard unix > 0 else { return "" }
        return dayFormatter.string(from: Date(timeIntervalSince1970: unix))
    }

    public static func timeOnly(_ unix: Double) -> String {
        guard unix > 0 else { return "" }
        return timeFormatter.string(from: Date(timeIntervalSince1970: unix))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
