import Foundation
import UIKit

struct ClipInfo: Equatable {
    var url: URL
    var date: Date
    var name: String
    var seconds: Double
}

struct TapeInfo: Equatable, Identifiable {
    var url: URL
    var created: Date
    var name: String
    var label: LabelSpec
    var id: String { url.lastPathComponent }
}

/// Tapes are folders, clips are WAV files, the label is a one-line `pattern` file plus an
/// optional `ink.png` drawn with a finger. Nothing else is stored anywhere.
final class TapeStore {
    let root: URL
    private let fm = FileManager.default

    init(root: URL? = nil) {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? docs.appendingPathComponent("tapes", isDirectory: true)
        try? fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func tapes() -> [TapeInfo] {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { url -> TapeInfo? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let parsed = Naming.parse(url.lastPathComponent)
            let name = parsed?.label ?? url.lastPathComponent
            let created = parsed?.date ?? ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date())
            return TapeInfo(url: url, created: created, name: name, label: readLabel(url, name: name))
        }.sorted { $0.created < $1.created }
    }

    @discardableResult
    func create(name: String, date: Date = Date()) -> TapeInfo {
        let url = root.appendingPathComponent(Naming.tapeFolder(date: date, name: name), isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        let clean = Naming.clean(name)
        let spec = LabelSpec(pattern: Pattern.derived(from: clean), pair: Pattern.derivedPair(from: clean))
        writeLabel(url, spec)
        return TapeInfo(url: url, created: date, name: clean, label: spec)
    }

    /// Renaming a tape is renaming its folder. The timestamp stays, so it keeps its place.
    func rename(_ tape: TapeInfo, to name: String) -> TapeInfo {
        let dest = root.appendingPathComponent(Naming.tapeFolder(date: tape.created, name: name), isDirectory: true)
        guard dest != tape.url else { return tape }
        do { try fm.moveItem(at: tape.url, to: dest) } catch { return tape }
        var t = tape; t.url = dest; t.name = Naming.clean(name)
        return t
    }

    /// Refuses a tape that still has clips on it. A recursive delete across recordings is the
    /// one unrecoverable mistake this app could make.
    func delete(_ tape: TapeInfo) -> Bool {
        guard clips(in: tape).isEmpty else { return false }
        return (try? fm.removeItem(at: tape.url)) != nil
    }

    func clips(in tape: TapeInfo) -> [ClipInfo] {
        let files = (try? fm.contentsOfDirectory(at: tape.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let h = WavHeader.read(url: url), h.seconds > 0.05 else { return nil }
                let p = Naming.parse(url.lastPathComponent)
                return ClipInfo(url: url, date: p?.date ?? Date(), name: p?.label ?? url.deletingPathExtension().lastPathComponent, seconds: h.seconds)
            }
    }

    func newClipURL(in tape: TapeInfo, date: Date = Date()) -> URL {
        tape.url.appendingPathComponent(Naming.clipFile(date: date, place: Naming.fallbackPlace))
    }

    /// The place arrives after the recording has started, sometimes after it has stopped.
    func renameClip(_ url: URL, place: String) -> URL {
        guard let p = Naming.parse(url.lastPathComponent) else { return url }
        let dest = url.deletingLastPathComponent().appendingPathComponent(Naming.clipFile(date: p.date, place: place))
        guard dest != url, !fm.fileExists(atPath: dest.path) else { return url }
        return (try? fm.moveItem(at: url, to: dest)) != nil ? dest : url
    }

    func readLabel(_ url: URL, name: String) -> LabelSpec {
        if let s = try? String(contentsOf: url.appendingPathComponent("pattern"), encoding: .utf8), let spec = LabelSpec(line: s) { return spec }
        return LabelSpec(pattern: Pattern.derived(from: name), pair: Pattern.derivedPair(from: name))
    }

    func writeLabel(_ url: URL, _ spec: LabelSpec) {
        try? (spec.line + "\n").write(to: url.appendingPathComponent("pattern"), atomically: true, encoding: .utf8)
    }

    func inkURL(_ tape: TapeInfo) -> URL { tape.url.appendingPathComponent("ink.png") }

    func loadInk(_ tape: TapeInfo) -> UIImage? { UIImage(contentsOfFile: inkURL(tape).path) }

    func saveInk(_ image: UIImage?, for tape: TapeInfo) {
        if let image, let png = image.pngData() { try? png.write(to: inkURL(tape)) }
        else { try? fm.removeItem(at: inkURL(tape)) }
    }
}
