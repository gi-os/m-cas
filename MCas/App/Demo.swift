import Foundation

/// Sample tapes for the App Store screenshots, on with `-demo` or under fastlane snapshot.
/// They live in a temporary folder; the real tapes are never touched, and nothing records.
///   -screen deck|shelf|clips|edit|label   which screen opens
///   -flipped                              the Deck's cassette shows the waveform
///   -layers                               the editor opens in layers view
enum Demo {
    static let args = ProcessInfo.processInfo.arguments
    static var active: Bool { args.contains("-demo") || args.contains("-FASTLANE_SNAPSHOT") }
    static var screen: Screen {
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return .deck }
        return ["deck": .deck, "shelf": .shelf, "clips": .clips, "edit": .edit, "label": .label][args[i + 1]] ?? .deck
    }
    static var flipped: Bool { args.contains("-flipped") }
    static var layers: Bool { args.contains("-layers") }

    static func store() -> TapeStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("demo-tapes", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let s = TapeStore(root: root)
        let cal = Calendar.current
        func when(_ daysAgo: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: -daysAgo, to: Date())!)!
        }
        let tapes: [(String, Pattern, Int, Int, [(String, Double, Int, Int)])] = [
            ("2026", .stripes, 2, 200, [("Brooklyn Bridge Park", 50, 9, 20), ("F Train, Delancey", 38, 18, 5)]),
            ("The apt", .spots, 1, 120, [("Kitchen, Lower East Side", 64, 8, 12), ("Fire escape", 90, 23, 40)]),
            ("Basil noises", .photo, 3, 60, [("Purring on the couch", 30, 22, 15), ("3 AM zoomies", 24, 3, 2)]),
            ("Trip to Rome", .bands, 0, 30, [("Hotel Monti, Rome", 48, 22, 10), ("Campo de' Fiori, Rome", 70, 9, 2),
                                            ("Trastevere, Rome", 62, 14, 39), ("Tram 8", 36, 18, 20), ("Piazza Navona, Rome", 80, 21, 47)])
        ]
        var seed: UInt32 = 1
        for (name, pattern, pair, daysAgo, clips) in tapes {
            let tape = s.create(name: name, date: when(daysAgo, 12, 0))
            s.writeLabel(tape.url, LabelSpec(pattern: pattern, pair: pair))
            for (k, c) in clips.enumerated() {
                let date = when(daysAgo - k, c.2, c.3)
                let url = tape.url.appendingPathComponent(Naming.clipFile(date: date, place: c.0))
                seed &+= 7
                try? wav(seconds: c.1, seed: seed).write(to: url)
            }
            // A take recorded over the middle of the Rome tape, so the red layer shows.
            if name == "Trip to Rome" {
                let date = when(daysAgo - 5, 20, 5)
                let url = tape.url.appendingPathComponent(Naming.clipFile(date: date, place: "Pantheon, Rome"))
                try? wav(seconds: 26, seed: 99).write(to: url)
                var e = Edits()
                e.takes[Edits.key(url)] = 131
                e.save(tape.url)
            }
        }
        UserDefaults.standard.set([String: Double](), forKey: "positions")
        return s
    }

    /// Room tone with swells: filtered noise under a slow, uneven envelope, 16 kHz mono.
    static func wav(seconds: Double, seed: UInt32) -> Data {
        let sr = 16000, n = Int(seconds * Double(sr))
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        var x = seed == 0 ? 1 : seed
        var lp: Double = 0
        let phase = Double(seed % 17)
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let noise = Double(Int32(bitPattern: x)) / Double(Int32.max)
            lp += (noise - lp) * 0.18
            let t = Double(i) / Double(sr)
            let env = 0.18 + 0.5 * pow(abs(sin(t * 0.7 + phase)), 3) + 0.3 * pow(abs(sin(t * 2.3 + phase * 0.5)), 8)
            samples[i] = Int16(max(-32000, min(32000, lp * env * 26000)))
        }
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
