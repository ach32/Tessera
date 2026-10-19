import Foundation

/// Case-insensitive `*` / `?` matcher over UTF-8 bytes (ASCII case folding).
/// A pattern with no wildcard matches anywhere in the name ("photo" == "*photo*").
public struct Glob: Equatable {
    public let pattern: String
    private let bytes: [UInt8]
    private let suffix: [UInt8]?   // fast path for "*.ext"

    public init(_ pattern: String) {
        var p = pattern
        if !p.contains("*") && !p.contains("?") { p = "*" + p + "*" }
        self.pattern = p
        bytes = Array(p.utf8).map(Glob.fold)
        if bytes.first == 42, !bytes.dropFirst().contains(42), !bytes.contains(63) {
            suffix = Array(bytes.dropFirst())
        } else {
            suffix = nil
        }
    }

    @inline(__always)
    static func fold(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }

    public func matches(_ name: String) -> Bool {
        var name = name
        return name.withUTF8 { match($0) }
    }

    private func match(_ s: UnsafeBufferPointer<UInt8>) -> Bool {
        if let suffix {
            guard s.count >= suffix.count else { return false }
            let off = s.count - suffix.count
            for i in 0..<suffix.count where Glob.fold(s[off + i]) != suffix[i] { return false }
            return true
        }
        let p = bytes
        var si = 0, pi = 0
        var star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == 63 || p[pi] == Glob.fold(s[si])) {
                si += 1; pi += 1
            } else if pi < p.count && p[pi] == 42 {
                star = pi; mark = si; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == 42 { pi += 1 }
        return pi == p.count
    }
}

/// Fuzzy keyword matching: "dsksz" finds "disksize". Exact beats prefix beats subsequence;
/// the first letter must match.
public enum Fuzzy {
    public static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        outer: for c in needle {
            while let h = it.next() {
                if h == c { continue outer }
            }
            return false
        }
        return true
    }

    /// candidates: (word, value). Returns the best value or nil.
    public static func pick<T>(_ word: String, _ candidates: [(String, T)]) -> T? {
        let w = word.lowercased()
        guard let first = w.first else { return nil }
        if let hit = candidates.first(where: { $0.0 == w }) { return hit.1 }
        if let hit = candidates.first(where: { $0.0.hasPrefix(w) }) { return hit.1 }
        if let hit = candidates.first(where: { $0.0.first == first && isSubsequence(w, of: $0.0) }) { return hit.1 }
        return nil
    }
}
