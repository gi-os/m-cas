import AVFoundation
import UIKit

/// Values the audio thread reads. Plain stores; the clip array is only swapped while the
/// playback engine is paused.
final class HeadState {
    var position: Double = 0
    var rate: Double = 0
    var timeline = Timeline(clips: [])
    var clips: [MappedWav] = []
    var outRate: Double = 48000
}

final class LevelBox { var level: Float = 0 }

/// The tape machine: one tape on it at a time, one signed rate, one position.
///
/// Playback is an AVAudioSourceNode running BrightRecorder's TapeEngine loop — read the
/// rate, read a sample at the position, move the position by the rate. Winding is playing at
/// four times the speed; rewind is the same with the sign flipped. Recording runs on its own
/// engine that exists only while recording, so the microphone indicator is off the rest of
/// the time.
final class Machine: ObservableObject {
    static let shared = Machine()

    @Published private(set) var tapes: [TapeInfo] = []
    @Published private(set) var current = 0
    @Published private(set) var timeline = Timeline(clips: [])
    @Published private(set) var position: Double = 0
    @Published private(set) var rate: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var recording = false
    @Published private(set) var recSeconds: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var inks: [String: UIImage] = [:]
    @Published var holdRate: Double?
    private var totals: [String: Double] = [:]
    @Published var nameDraft = ""

    let store = TapeStore()
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let head = HeadState()
    private var scrub = Scrub()
    private var recEngine: AVAudioEngine?
    private var recFile: AVAudioFile?
    private var recURL: URL?
    private var recStarted = Date()
    private let levels = LevelBox()
    private var ticker: Timer?
    private let places = PlaceNamer()
    private var placeFor: [URL: String] = [:]
    private var saved: [String: Double] = [:]
    private var started = false

    private init() {}

    var tape: TapeInfo? { tapes.indices.contains(current) ? tapes[current] : nil }
    var clipIndex: Int? { timeline.clipIndex(at: position) }

    func start() {
        guard !started else { return }
        started = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)

        let out = engine.outputNode.outputFormat(forBus: 0)
        head.outRate = out.sampleRate > 0 ? out.sampleRate : 48000
        let fmt = AVAudioFormat(standardFormatWithSampleRate: head.outRate, channels: 1)!
        let node = Self.makeSource(head, fmt)
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try? engine.start()

        saved = (UserDefaults.standard.dictionary(forKey: "positions") as? [String: Double]) ?? [:]
        reloadTapes()
        if tapes.isEmpty { store.create(name: "First tape"); reloadTapes() }
        let last = UserDefaults.standard.string(forKey: "currentTape")
        load(tapes.firstIndex { $0.id == last } ?? tapes.count - 1)

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            self?.playing = false
            try? self?.engine.start()
        }
    }

    // MARK: render

    static func makeSource(_ head: HeadState, _ format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            let step = head.rate / head.outRate
            let tl = head.timeline
            let clips = head.clips
            var pos = head.position
            for f in 0..<n {
                var s: Float = 0
                if step != 0, !tl.isEmpty {
                    if let (i, off) = tl.locate(pos), i < clips.count { s = clips[i].sample(at: off) }
                    pos = min(max(0, pos + step), tl.total)
                }
                for b in bufs { b.mData?.assumingMemoryBound(to: Float.self)[f] = s }
            }
            head.position = pos
            return noErr
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var r: Double = 0
        if !recording {
            if let s = scrub.rate(at: now) { r = s }
            else if let h = holdRate { r = h }
            else if playing { r = 1 }
        }
        if r > 0, head.position >= timeline.total - 0.01 { r = 0; if holdRate == nil && scrub.rate(at: now) == nil { playing = false } }
        head.rate = r
        if rate != r { rate = r }
        let p = head.position
        if abs(p - position) > 0.0005 { position = p }
        if recording {
            recSeconds = Date().timeIntervalSince(recStarted)
            level = levels.level
        } else if level != 0 { level = 0 }
    }

    // MARK: transport

    func togglePlay() {
        if recording { stopRecording(); return }
        guard !timeline.isEmpty else { return }
        if !playing, position >= timeline.total - 0.05 { seek(0) }
        playing.toggle()
    }

    func seek(_ t: Double) {
        let c = min(max(0, t), timeline.total)
        head.position = c
        position = c
    }

    func notch(_ dir: Int) { scrub.notch(dir, at: CACurrentMediaTime()) }

    func play() { if !timeline.isEmpty { playing = true } }

    // MARK: recording

    func toggleRecording() { recording ? stopRecording() : startRecording() }

    func startRecording() {
        guard !recording, tape != nil else { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async { if ok { self.beginRecording() } }
        }
    }

    private func beginRecording() {
        guard !recording, let tape else { return }
        playing = false
        head.rate = 0
        let date = Date()
        let url = store.newClipURL(in: tape, date: date)
        let e = AVAudioEngine()
        let input = e.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inFmt.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
        Self.installTap(input, inFmt, file, levels)
        e.prepare()
        do { try e.start() } catch { input.removeTap(onBus: 0); return }
        recEngine = e
        recFile = file
        recURL = url
        recStarted = date
        recording = true
        recSeconds = 0
        places.lookup { [weak self] place in
            guard let self, let place else { return }
            if self.recURL == url { self.placeFor[url] = place } else { self.applyPlace(place, to: url) }
        }
    }

    static func installTap(_ input: AVAudioInputNode, _ fmt: AVAudioFormat, _ file: AVAudioFile, _ box: LevelBox) {
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
            guard let ch = buf.floatChannelData,
                  let mono = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: buf.frameLength),
                  let dst = mono.floatChannelData else { return }
            let n = Int(buf.frameLength)
            mono.frameLength = buf.frameLength
            var sum: Float = 0
            for i in 0..<n { let v = ch[0][i]; dst[0][i] = v; sum += v * v }
            box.level = n > 0 ? (sum / Float(n)).squareRoot() : 0
            try? file.write(from: mono)
        }
    }

    func stopRecording() {
        guard recording else { return }
        recEngine?.inputNode.removeTap(onBus: 0)
        recEngine?.stop()
        recEngine = nil
        recFile = nil
        recording = false
        let oldTotal = timeline.total
        if let url = recURL {
            recURL = nil
            if let place = placeFor.removeValue(forKey: url) { _ = store.renameClip(url, place: place) }
        }
        reloadCurrent()
        seek(oldTotal)
    }

    private func applyPlace(_ place: String, to url: URL) {
        _ = store.renameClip(url, place: place)
        let p = position
        reloadCurrent()
        seek(p)
    }

    // MARK: tapes

    func reloadTapes() {
        tapes = store.tapes()
        var i: [String: UIImage] = [:]
        for t in tapes { if let img = store.loadInk(t) { i[t.id] = img } }
        inks = i
        var tot: [String: Double] = [:]
        for t in tapes { tot[t.id] = store.clips(in: t).reduce(0) { $0 + $1.seconds } }
        totals = tot
    }

    func load(_ index: Int) {
        guard tapes.indices.contains(index) else { return }
        if let t = tape { saved[t.id] = position }
        current = index
        let t = tapes[index]
        nameDraft = t.name
        UserDefaults.standard.set(t.id, forKey: "currentTape")
        swapIn(t, at: saved[t.id])
    }

    private func reloadCurrent() {
        guard let t = tape else { return }
        swapIn(t, at: position)
    }

    private func swapIn(_ t: TapeInfo, at pos: Double?) {
        var clips: [Timeline.Clip] = []
        var mapped: [MappedWav] = []
        for c in store.clips(in: t) {
            guard let m = MappedWav(url: c.url) else { continue }
            clips.append(.init(url: c.url, seconds: m.seconds, date: c.date, name: c.name))
            mapped.append(m)
        }
        let tl = Timeline(clips: clips)
        head.rate = 0
        engine.pause()
        head.clips = mapped
        head.timeline = tl
        head.position = min(max(0, pos ?? 0), tl.total)
        try? engine.start()
        timeline = tl
        position = head.position
        totals[t.id] = tl.total
        persist()
    }

    func select(_ index: Int) {
        guard index != current else { return }
        playing = false
        load(index)
        persist()
    }

    func newTape() {
        guard !recording else { return }
        let t = store.create(name: "New tape")
        reloadTapes()
        if let i = tapes.firstIndex(where: { $0.id == t.id }) { select(i) }
    }

    func renameCurrent(_ name: String) {
        guard let t = tape, !recording else { nameDraft = tape?.name ?? ""; return }
        let clean = Naming.clean(name)
        guard clean != t.name else { nameDraft = t.name; return }
        let p = position
        let moved = store.rename(t, to: clean)
        if let pos = saved.removeValue(forKey: t.id) { saved[moved.id] = pos }
        reloadTapes()
        if let i = tapes.firstIndex(where: { $0.id == moved.id }) { current = i; nameDraft = moved.name; swapIn(moved, at: p) }
    }

    func setLabel(pattern: Pattern? = nil, pair: Int? = nil) {
        guard let t = tape else { return }
        var spec = t.label
        if let pattern { spec.pattern = pattern }
        if let pair { spec.pair = pair }
        store.writeLabel(t.url, spec)
        tapes[current].label = spec
    }

    func setInk(_ image: UIImage?, save: Bool) {
        guard let t = tape else { return }
        inks[t.id] = image
        if save { store.saveInk(image, for: t) }
    }

    func totalSeconds(_ t: TapeInfo) -> Double {
        if t.id == tape?.id { return timeline.total }
        return totals[t.id] ?? 0
    }

    private func persist() {
        if let t = tape { saved[t.id] = position }
        UserDefaults.standard.set(saved, forKey: "positions")
    }

    func savePosition() { persist() }
}
