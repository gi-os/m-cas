import Foundation

/// File and folder names, which are the whole database.
///
/// `tapes/2026-08-17 143205 Trip to Rome/2026-08-17 143912 Trastevere, Rome.wav`
/// Timestamp first so everything sorts by when it happened; the human name after, so the
/// store reads as itself in the Files app. Same layout as BrightRecorder, so a tape folder
/// can move between the two phones.
enum Naming {
    static let fallbackPlace = "Somewhere"

    private static func formatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }

    static func stamp(_ date: Date, tz: TimeZone = .current) -> String { formatter(tz).string(from: date) }

    static func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let parts = s.components(separatedBy: bad).joined(separator: "-")
        let squashed = parts.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let trimmed = squashed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallbackPlace : String(trimmed.prefix(80))
    }

    static func clipFile(date: Date, place: String, tz: TimeZone = .current) -> String {
        "\(stamp(date, tz: tz)) \(clean(place)).wav"
    }

    static func tapeFolder(date: Date, name: String, tz: TimeZone = .current) -> String {
        "\(stamp(date, tz: tz)) \(clean(name))"
    }

    /// The date and human label back out of a clip file or tape folder name.
    static func parse(_ name: String, tz: TimeZone = .current) -> (date: Date, label: String)? {
        var base = name
        if base.lowercased().hasSuffix(".wav") { base = String(base.dropLast(4)) }
        guard base.count >= 17 else { return nil }
        let head = String(base.prefix(17))
        guard let d = formatter(tz).date(from: head) else { return nil }
        let rest = base.dropFirst(17).trimmingCharacters(in: .whitespaces)
        return (d, rest.isEmpty ? fallbackPlace : rest)
    }

    /// "AUG 17 14:39", the way the deck and the clip list print a time.
    static func short(_ date: Date, tz: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "MMM dd HH:mm"
        return f.string(from: date).uppercased()
    }
}
