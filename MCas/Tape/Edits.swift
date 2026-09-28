import Foundation

/// `edits.json` in a tape folder: trims and takes, keyed by each clip's timestamp (the first
/// 17 characters of its file name, which never change when a clip is renamed).
struct Edits: Codable, Equatable {
    struct Trim: Codable, Equatable { var trimIn: Double; var trimOut: Double? }
    var trims: [String: Trim] = [:]
    var takes: [String: Double] = [:]   // key → tape position it was recorded at

    static func key(_ url: URL) -> String { String(url.lastPathComponent.prefix(17)) }

    static func load(_ folder: URL) -> Edits {
        (try? JSONDecoder().decode(Edits.self, from: Data(contentsOf: folder.appendingPathComponent("edits.json")))) ?? Edits()
    }

    func save(_ folder: URL) {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: folder.appendingPathComponent("edits.json"), options: .atomic) }
    }

    func apply(to c: Timeline.Clip) -> Timeline.Clip {
        var c = c
        let k = Edits.key(c.url)
        if let t = trims[k] { c.trimIn = max(0, min(t.trimIn, c.seconds)); c.trimOut = t.trimOut }
        c.overdubAt = takes[k]
        return c
    }
}
