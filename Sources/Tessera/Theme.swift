import AppKit
import TesseraCore

/// Treemap palette. Window chrome uses system colours.
enum Theme {
    static let canvas = NSColor(hex: "#1E2228")
    static let accent = NSColor(hex: "#FFB547")
    static let selectionOuter = NSColor(hex: "#101317")
    static let darkText = NSColor(hex: "#14202E")
    static let tooltipBackground = NSColor(hex: "#101317").withAlphaComponent(0.95)
    static let tooltipText = NSColor(hex: "#F2F4F7")
    static let tooltipMuted = NSColor(hex: "#A9B1BC")

    static func tagColor(_ tag: Tag) -> NSColor {
        switch tag {
        case .none: return .clear
        case .red: return NSColor(hex: "#E5484D")
        case .yellow: return NSColor(hex: "#F5C518")
        case .green: return NSColor(hex: "#2FA36B")
        case .blue: return NSColor(hex: "#3E63DD")
        }
    }

    /// White or dark text, whichever reads better on `background`.
    static func text(on background: NSColor) -> NSColor {
        background.relativeLuminance > 0.40 ? darkText : .white
    }
}

extension NSColor {
    /// "#RRGGBB" or "RRGGBB", sRGB. Falls back to grey.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0x808080
        if s.count == 6, let parsed = UInt64(s, radix: 16) { v = parsed }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    var relativeLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ x: CGFloat) -> CGFloat { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    func mixed(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        let f = max(0, min(1, fraction))
        guard f > 0 else { return self }
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * f)
    }

    func darker(_ f: CGFloat) -> NSColor { mixed(with: .black, f) }
    func lighter(_ f: CGFloat) -> NSColor { mixed(with: .white, f) }
}
