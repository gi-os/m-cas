import AVFoundation
import UIKit
import MediaPlayer
import ActivityKit
import CoreLocation

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
    /// What the hidden text field is renaming: the tape, or one clip's place.
    enum Editing: Equatable { case tape, clip(URL) }
    @Published var editing: Editing = .tape
    /// Sky (the starry gradient), black (the palette's darkest, a blue-black), or OLED
    /// (true black, so the pixels switch off).
    enum Background: String, CaseIterable { case sky, black, oled
        var title: String { rawValue.uppercased() }
    }
    @Published var background = Background(rawValue: UserDefaults.standard.string(forKey: "background") ?? "") ??
        (UserDefaults.standard.bool(forKey: "blackBackground") ? .black : .sky) {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: "background") }
    }
    var blackBackground: Bool { background != .sky }
    @Published var keyClicks = UserDefaults.standard.object(forKey: "keyClicks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keyClicks, forKey: "keyClicks") }
    }
    private var activity: Activity<RecordingAttributes>?
    private var recPlace = "Somewhere"
    private var recCoordinate: CLLocationCoordinate2D?
    private var lastNowPlaying: Double = 0

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
        setupRemoteCommands()
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
        if now - lastNowPlaying > 1 { lastNowPlaying = now; updateNowPlaying() }
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

    /// A tap on ◀◀ or ▶▶: back to the start of this clip (or the one before, if you're
    /// already near its start), or on to the next clip.
    func skip(_ dir: Int) {
        guard let i = timeline.clipIndex(at: position) else { return }
        if dir < 0 {
            let start = timeline.start(of: i)
            seek(position - start > 2 || i == 0 ? start : timeline.start(of: i - 1))
        } else if i + 1 < timeline.clips.count {
            seek(timeline.start(of: i + 1))
        } else {
            seek(timeline.total)
        }
    }

    // MARK: lock screen and Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.playing = false; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(1); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skip(-1); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(e.positionTime); return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = tape, !timeline.isEmpty else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        let clip = clipIndex.map { timeline.clips[$0] }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: clip?.name ?? t.name,
            MPMediaItemPropertyArtist: t.name,
            MPMediaItemPropertyAlbumTitle: clip.map { Naming.short($0.date) } ?? "m-cas",
            MPMediaItemPropertyPlaybackDuration: timeline.total,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0
        ]
    }

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
        recPlace = "Finding where you are"
        recCoordinate = nil
        startActivity(tape: tape.name, started: date)
        places.lookup { [weak self] fix in
            guard let self, let fix else { return }
            if let c = fix.coordinate { self.store.setCoordinate(c, for: url) }
            if self.recURL == url {
                self.placeFor[url] = fix.name
                self.recPlace = fix.name
                self.updateActivity()
            } else { self.applyPlace(fix.name, to: url) }
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
        endActivity()
        let oldTotal = timeline.total
        if let url = recURL {
            recURL = nil
            if let place = placeFor.removeValue(forKey: url) { _ = store.renameClip(url, place: place) }
        }
        reloadCurrent()
        seek(oldTotal)
    }

    // MARK: Live Activity

    private func startActivity(tape: String, started: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingAttributes.ContentState(place: recPlace, started: started)
        activity = try? Activity.request(attributes: RecordingAttributes(tape: tape), content: .init(state: state, staleDate: nil))
    }

    private func updateActivity() {
        guard let a = activity else { return }
        let state = RecordingAttributes.ContentState(place: recPlace, started: recStarted)
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        guard let a = activity else { return }
        activity = nil
        let state = RecordingAttributes.ContentState(place: recPlace, started: recStarted)
        Task { await a.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate) }
    }

    // MARK: renaming

    /// Rename a clip's place. If we know where it was recorded, that spot keeps the name:
    /// the next clip recorded there is called the same thing.
    func beginClipRename(_ index: Int) {
        guard timeline.clips.indices.contains(index) else { return }
        let c = timeline.clips[index]
        editing = .clip(c.url)
        nameDraft = c.name
    }

    func beginTapeRename() {
        editing = .tape
        nameDraft = tape?.name ?? ""
    }

    func commitName() {
        switch editing {
        case .tape: renameCurrent(nameDraft)
        case .clip(let url):
            let name = Naming.clean(nameDraft)
            if let c = store.coordinate(for: url) { PlaceBook.remember(name, at: c) }
            let p = position
            _ = store.renameClip(url, place: name)
            editing = .tape
            nameDraft = tape?.name ?? ""
            reloadCurrent()
            seek(p)
        }
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
