import Foundation

/// How one tape is told apart from another on the shelf.
///
/// On the LP3 these were black and white by necessity. Here each pattern comes in a color
/// pair, and a photo label runs through the same dither as everything else.
enum Pattern: String, CaseIterable, Codable {
    case bands, spots, stripes, checks, waves, photo

    /// A stable pattern for a tape that never chose one, derived from its name the way the
    /// Android app does (Java's String.hashCode), so a folder copied between phones matches.
    static func derived(from name: String) -> Pattern {
        let drawn: [Pattern] = [.bands, .spots, .stripes, .checks, .waves]
        let h = UInt32(bitPattern: javaHash(name))
        return drawn[Int(h % UInt32(drawn.count))]
    }

    static func derivedPair(from name: String) -> Int {
        Int(UInt32(bitPattern: javaHash(name)) / 7 % 6)
    }

    static func javaHash(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 { h = 31 &* h &+ Int32(u) }
        return h
    }
}

/// The label as stored in the tape folder's `pattern` file: "bands 0".
struct LabelSpec: Equatable {
    var pattern: Pattern
    var pair: Int

    var line: String { "\(pattern.rawValue) \(pair)" }

    init(pattern: Pattern, pair: Int) { self.pattern = pattern; self.pair = max(0, min(5, pair)) }

    init?(line: String) {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: " ")
        guard let first = parts.first, let p = Pattern(rawValue: String(first)) else { return nil }
        let pair = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        self.init(pattern: p, pair: pair)
    }
}
