import Foundation

/// Update check logic that needs no network: reading the version out of the Homebrew formula, and
/// comparing versions. The fetch itself lives in MogEngine (`UpdateChecker`).
public enum UpdateInfo {
    /// The version the formula installs, from its source URL: `.../refs/tags/v0.3.0.tar.gz` → `0.3.0`.
    /// Nil if the formula has no such URL.
    public static func version(inFormula text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only the formula's own `url`, not a resource's (those are indented deeper, but check the shape).
            guard trimmed.hasPrefix("url \""), let tags = trimmed.range(of: "/refs/tags/v"),
                  let end = trimmed.range(of: ".tar.gz\"", range: tags.upperBound..<trimmed.endIndex)
            else { continue }
            let v = String(trimmed[tags.upperBound..<end.lowerBound])
            if parse(v) != nil { return v }
        }
        return nil
    }

    /// True if `candidate` is a later version than `current` (numeric, dot-separated; `0.3` == `0.3.0`).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parse(candidate), let b = parse(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// `1.2.3` → [1, 2, 3]; nil for anything else (pre-release tags, letters, empty parts).
    static func parse(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }
}
