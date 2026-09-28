import AVFoundation
import UIKit
import MediaPlayer
import ActivityKit
import CoreLocation

/// Values the audio thread reads. Plain stores; the clip array is only swapped while the
/// playback engine is paused.
final class HeadState {
    var position: Double = 0
    var level: Float = 0
    var rate: Double = 0
    var timeline = Timeline(clips: [])
    var clips: [MappedWav] = []
    var outRate: Double = 48000
}

final class LevelBox {
    var level: Float = 0
    private var pending: [Float] = []
    private let lock = NSLock()
    func push(_ p: Float) { lock.lock(); pending.append(p); lock.unlock() }
    func drain() -> [Float] { lock.lock(); defer { pending = []; lock.unlock() }; return pending }
}

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
    @Published private(set) var playing = false {
        didSet {
            guard playing != oldValue else { return }
            if playing { wakeAudio(); pausedAt = nil } else { pausedAt = CACurrentMediaTime() }
            updateNowPlaying()
        }
    }
    private var pausedAt: Double?
    private var nowPlayingShown = false
    private var lastNowPlayingClip: Int?
    private var audioAsleep = false
    private var artworkKey = ""
    private var artwork: MPMediaItemArtwork?
    @Published private(set) var recording = false
    @Published private(set) var recSeconds: Double = 0
    @Published private(set) var level: Float = 0
    /// The take being recorded, as waveform peaks, oldest first (about 12 a second).
    @Published private(set) var recPeaks: [Float] = []
    @Published private(set) var inks: [String: UIImage] = [:]
    @Published var holdRate: Double?
    private var totals: [String: Double] = [:]
    @Published var nameDraft = ""
    /// What the hidden text field is renaming: the tape, or one clip's place.
    enum Editing: Equatable { case tape, clip(URL), take }
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
    /// Where ● records over the tape. Nil: record onto the end.
    @Published var mark: Double?
    /// Trims and takes for the tape on the machine.
    @Published private(set) var edits = Edits()
    /// Waveform peaks per clip file: one value per 20 ms, 0...1.
    @Published private(set) var peaks: [URL: [Float]] = [:]
    static let peaksPerSecond = 50.0
    /// Playing one clip's whole original file (the editor's layers view), or nil.
    @Published private(set) var solo: Int?
    private var mappedAll: [MappedWav] = []
    private var recTakeAt: Double?
    private var recStartPosition: Double = 0

    /// The take just recorded, waiting for you to say where it goes and what it's called.
    struct PendingTake: Equatable {
        var url: URL
        var seconds: Double
        var spot: Double       // where "HERE" puts it: the mark, or where you pressed record
        var atSpot: Bool
        var name: String
        var named = false      // you typed a name, so a late place lookup won't replace it
    }
    @Published private(set) var pendingTake: PendingTake?
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
            // Loudness of what just played, for the meter.
            if let b = bufs.first, let d = b.mData?.assumingMemoryBound(to: Float.self), n > 0 {
                var sum: Float = 0
                for f in 0..<n { sum += d[f] * d[f] }
                head.level = (sum / Float(n)).squareRoot()
            }
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
        if r > 0, head.position >= head.timeline.total - 0.01 { r = 0; if holdRate == nil && scrub.rate(at: now) == nil { playing = false } }
        if r != 0 && audioAsleep { wakeAudio() }
        head.rate = r
        if rate != r { rate = r }
        let p = head.position
        if abs(p - position) > 0.0005 { position = p }
        // Keep the lock screen in step: on every clip change at once, otherwise every few seconds.
        let ci = clipIndex
        if ci != lastNowPlayingClip || now - lastNowPlaying > 5 { lastNowPlayingClip = ci; lastNowPlaying = now; updateNowPlaying() }
        // Paused for half a minute, or run off the end: take it off the lock screen.
        if nowPlayingShown, !playing, !recording, holdRate == nil, let p = pausedAt, now - p > 30 { clearNowPlaying() }
        if recording {
            recSeconds = Date().timeIntervalSince(recStarted)
            level = levels.level
            let new = levels.drain()
            if !new.isEmpty { recPeaks.append(contentsOf: new) }
        } else {
            let l = r != 0 ? head.level : 0
            if abs(l - level) > 0.001 || (l == 0 && level != 0) { level = l }
        }
    }

    // MARK: transport

    func togglePlay() {
        if recording { stopRecording(); return }
        guard !head.timeline.isEmpty else { return }
        if !playing, position >= head.timeline.total - 0.05 { seek(0) }
        playing.toggle()
    }

    func seek(_ t: Double) {
        let c = min(max(0, t), head.timeline.total)
        head.position = c
        position = c
    }

    func notch(_ dir: Int) { scrub.notch(dir, at: CACurrentMediaTime()) }

    func play() { if !timeline.isEmpty { playing = true } }

    /// A tap on ◀◀ or ▶▶: back to the start of this clip (or the one before, if you're
    /// already near its start), or on to the next clip.
    func skip(_ dir: Int) {
        guard let i = timeline.segmentIndex(at: position) else { return }
        if dir < 0 {
            let start = timeline.start(of: i)
            seek(position - start > 2 || i == 0 ? start : timeline.start(of: i - 1))
        } else if i + 1 < timeline.segments.count {
            seek(timeline.start(of: i + 1))
        } else {
            seek(timeline.total)
        }
    }

    // MARK: lock screen and Control Center

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.playing = false; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(1); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skip(-1); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(e.positionTime); self?.updateNowPlaying(); return .success
        }
    }

    /// Lock screen and Control Center: the clip as the title, the tape as the album, the
    /// tape's cassette as the artwork. Paused shows paused; nothing playing shows nothing.
    private func updateNowPlaying() {
        guard let t = tape, !timeline.isEmpty, !recording, solo == nil else { clearNowPlaying(); return }
        guard playing || nowPlayingShown else { return }   // never put it up just for a pause
        let clip = clipIndex.map { timeline.clips[$0] }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: clip?.name ?? t.name,
            MPMediaItemPropertyArtist: clip.map { Naming.short($0.date) } ?? "m-cas",
            MPMediaItemPropertyAlbumTitle: t.name,
            MPMediaItemPropertyPlaybackDuration: timeline.total,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let art = artwork(for: t) { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        nowPlayingShown = true
    }

    private func clearNowPlaying() {
        guard nowPlayingShown else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        nowPlayingShown = false
        pausedAt = nil
        sleepAudio()
    }

    /// Letting go of the audio session is what makes iOS drop the player from the lock
    /// screen. It's taken back the moment you press play.
    private func sleepAudio() {
        guard !audioAsleep, !recording, !playing else { return }
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioAsleep = true
    }

    private func wakeAudio() {
        guard audioAsleep else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        audioAsleep = false
    }

    /// The tape on the shelf, drawn by the same pixel renderer, blown up without smoothing.
    private func artwork(for t: TapeInfo) -> MPMediaItemArtwork? {
        let key = "\(t.id)|\(t.label.line)|\(inks[t.id]?.hash ?? 0)|\(background.rawValue)"
        if key == artworkKey, let a = artwork { return a }
        let canvas = PixelCanvas(width: 128, height: 128)
        let frac = timeline.fraction(position)
        guard let cg = canvas.frame(offset: .zero, oled: background == .oled, { c, full in
            Sky.draw(c, 0, Ink.hex(0x283870), Ink.hex(0x141428), Ink.hex(0x1c2c40), in: full)
            Pix.glow(c, CGPoint(x: 64, y: 64), 70, Ink.teal.withAlphaComponent(0.5))
            Cassette.draw(c, 8, 31, 112, 72, name: t.name, label: t.label, ink: self.inks[t.id], fraction: frac, rot: 0.6)
        }) else { return nil }
        let size = CGSize(width: 768, height: 768)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { r in
            r.cgContext.interpolationQuality = .none
            r.cgContext.translateBy(x: 0, y: size.height); r.cgContext.scaleBy(x: 1, y: -1)
            r.cgContext.draw(cg, in: CGRect(origin: .zero, size: size))
        }
        let art = MPMediaItemArtwork(boundsSize: size) { _ in img }
        artworkKey = key
        artwork = art
        return art
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
        wakeAudio()
        setSolo(nil)
        playing = false
        head.rate = 0
        recTakeAt = mark
        recStartPosition = position
        pendingTake = nil
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
        recPeaks = []
        _ = levels.drain()
        clearNowPlaying()
        recPlace = "Finding where you are"
        recCoordinate = nil
        startActivity(tape: tape, started: date)
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
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(ch[0][i])) }
            box.push(peak)
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
        let took = recSeconds
        let at = recTakeAt
        var saved: URL?
        var place = Naming.fallbackPlace
        if var url = recURL {
            recURL = nil
            // Recorded over the tape at the mark: note where, so it covers what was there.
            if let at, let t = tape {
                var e = Edits.load(t.url)
                e.takes[Edits.key(url)] = at
                e.save(t.url)
            }
            if let p = placeFor.removeValue(forKey: url) { url = store.renameClip(url, place: p); place = p }
            else { place = Naming.parse(url.lastPathComponent)?.label ?? place }
            saved = url
        }
        recTakeAt = nil
        mark = nil
        reloadCurrent()
        seek(at.map { $0 + took } ?? oldTotal)
        if let saved {
            pendingTake = PendingTake(url: saved, seconds: took, spot: at ?? recStartPosition, atSpot: at != nil, name: place)
        }
    }

    // MARK: editing

    /// Change a clip's in and out points. `save` writes edits.json; while dragging, the
    /// tape is rebuilt without touching the disk.
    func setTrim(clip i: Int, trimIn: Double, trimOut: Double, save: Bool) {
        guard timeline.clips.indices.contains(i), let t = tape else { return }
        let c = timeline.clips[i]
        let newIn = max(0, min(trimIn, c.seconds - 0.2))
        let newOut = max(newIn + 0.2, min(trimOut, c.seconds))
        var e = edits
        let k = Edits.key(c.url)
        // Trimming the front of a take keeps its audio where it was on the tape.
        if let at = e.takes[k] { e.takes[k] = max(0, at + (newIn - c.trimIn)) }
        e.trims[k] = .init(trimIn: newIn, trimOut: newOut >= c.seconds - 0.01 ? nil : newOut)
        applyEdits(e)
        if save { e.save(t.url) }
    }

    func resetTrim(clip i: Int) {
        guard timeline.clips.indices.contains(i), let t = tape else { return }
        let c = timeline.clips[i]
        var e = edits
        let k = Edits.key(c.url)
        if let at = e.takes[k] { e.takes[k] = max(0, at - c.trimIn) }
        e.trims[k] = nil
        applyEdits(e)
        e.save(t.url)
    }

    private func applyEdits(_ e: Edits) {
        let clips = timeline.clips.map { c -> Timeline.Clip in
            var base = c; base.trimIn = 0; base.trimOut = nil; base.overdubAt = nil
            return e.apply(to: base)
        }
        let tl = Timeline(clips: clips)
        let p = min(position, tl.total)
        engine.pause()
        head.timeline = tl
        head.position = p
        try? engine.start()
        edits = e
        timeline = tl
        position = p
        if let t = tape { totals[t.id] = tl.total }
    }

    /// Play one clip's whole original, covered parts included — or go back to the tape.
    func setSolo(_ i: Int?) {
        guard i != solo else { return }
        let wasPlaying = playing
        playing = false
        head.rate = 0
        engine.pause()
        if let i, timeline.clips.indices.contains(i), mappedAll.indices.contains(i) {
            var c = timeline.clips[i]; c.trimIn = 0; c.trimOut = nil; c.overdubAt = nil
            head.clips = [mappedAll[i]]
            head.timeline = Timeline(clips: [c])
            head.position = 0
        } else {
            head.clips = mappedAll
            head.timeline = timeline
            head.position = min(position, timeline.total)
        }
        try? engine.start()
        solo = i
        position = head.position
        if wasPlaying { playing = true }
    }

    /// The solo clip's playhead, in seconds into its file.
    var soloPosition: Double { head.position }

    private func computePeaks(_ files: [MappedWav]) {
        let missing = files.filter { peaks[$0.url] == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var out: [URL: [Float]] = [:]
            for f in missing { out[f.url] = f.peaks(perSecond: Machine.peaksPerSecond) }
            DispatchQueue.main.async { self.peaks.merge(out) { _, new in new } }
        }
    }

    func peak(_ url: URL, at seconds: Double) -> Float {
        guard let p = peaks[url], !p.isEmpty else { return 0 }
        let i = Int(seconds * Machine.peaksPerSecond)
        return i >= 0 && i < p.count ? p[i] : 0
    }

    // MARK: Live Activity

    private func startActivity(tape: TapeInfo, started: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let (a, b) = Ink.pairs[max(0, min(5, tape.label.pair))]
        let attrs = RecordingAttributes(tape: tape.name, clip: timeline.clips.count + 1, labelA: Self.hex(a), labelB: Self.hex(b))
        let state = RecordingAttributes.ContentState(place: recPlace, started: started)
        activity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil))
    }

    private static func hex(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func updateActivity() {
        guard let a = activity else { return }
        let state = RecordingAttributes.ContentState(place: recPlace, started: recStarted)
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    /// Stays up as a "saved" card for a few seconds, then goes.
    private func endActivity() {
        guard let a = activity else { return }
        activity = nil
        let state = RecordingAttributes.ContentState(place: recPlace, started: recStarted, saved: true, seconds: Date().timeIntervalSince(recStarted))
        Task { await a.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(6))) }
    }

    /// `mcas://play?clip=7` from the saved card: cue that clip and play it.
    func open(_ url: URL) {
        guard url.scheme == "mcas" else { return }
        if url.host == "play" {
            let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clip" })?.value.flatMap(Int.init)
            if let n, timeline.clips.indices.contains(n - 1) { seek(timeline.start(of: n - 1)) }
            play()
        }
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

    // MARK: the take just recorded

    /// END: attach to the end of the tape. HERE: record over from the spot.
    func placePendingTake(atSpot: Bool) {
        guard var pt = pendingTake, let t = tape, pt.atSpot != atSpot else { return }
        var e = Edits.load(t.url)
        e.takes[Edits.key(pt.url)] = atSpot ? pt.spot : nil
        e.save(t.url)
        pt.atSpot = atSpot
        pendingTake = pt
        reloadCurrent()
        if atSpot { seek(pt.spot) } else { seek(max(0, timeline.total - pt.seconds)) }
    }

    func beginTakeRename() {
        guard let pt = pendingTake else { return }
        editing = .take
        nameDraft = pt.name
    }

    func keepPendingTake() { pendingTake = nil; editing = .tape; nameDraft = tape?.name ?? "" }

    /// Throw the take away: its file and any edits for it.
    func discardPendingTake() {
        guard let pt = pendingTake, let t = tape else { return }
        var e = Edits.load(t.url)
        e.takes[Edits.key(pt.url)] = nil
        e.trims[Edits.key(pt.url)] = nil
        e.save(t.url)
        try? FileManager.default.removeItem(at: pt.url)
        pendingTake = nil
        editing = .tape
        nameDraft = tape?.name ?? ""
        let p = position
        reloadCurrent()
        seek(min(p, timeline.total))
    }

    func commitName() {
        switch editing {
        case .take:
            if var pt = pendingTake {
                let name = Naming.clean(nameDraft)
                pt.url = store.renameClip(pt.url, place: name)
                pt.name = name
                pt.named = true
                pendingTake = pt
                let p = position
                reloadCurrent()
                seek(p)
            }
            editing = .tape
            nameDraft = tape?.name ?? ""
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
        if let pt = pendingTake, pt.url == url, pt.named { return }
        let moved = store.renameClip(url, place: place)
        if var pt = pendingTake, pt.url == url { pt.url = moved; pt.name = place; pendingTake = pt }
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
        let e = Edits.load(t.url)
        for c in store.clips(in: t) {
            guard let m = MappedWav(url: c.url) else { continue }
            clips.append(e.apply(to: .init(url: c.url, seconds: m.seconds, date: c.date, name: c.name)))
            mapped.append(m)
        }
        let tl = Timeline(clips: clips)
        edits = e
        solo = nil
        mappedAll = mapped
        computePeaks(mapped)
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
