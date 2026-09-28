import UIKit
import SwiftUI
import AudioToolbox

enum Screen: Int, CaseIterable {
    case deck, shelf, clips, label, settings, edit
    var title: String { ["DECK", "SHELF", "CLIPS", "LABEL", "SETTINGS", "EDIT"][rawValue] }
    static let tabs: [Screen] = [.deck, .shelf, .clips, .edit, .label]
}

enum Tool: String { case draw, erase, none }

/// The frame of one screen, in canvas pixels. The canvas is sized to the display in whole
/// device pixels, so its width and height vary by phone; everything is placed against these
/// edges — header under the top inset, transport and tabs on the bottom inset, the cassette
/// as wide as the screen — rather than drawn into a fixed box.
struct Frame {
    let w: CGFloat, h: CGFloat
    let inset: CGFloat    // the status bar band: the Dynamic Island's row
    let bottom: CGFloat   // last usable row, above the home indicator
    /// With a status band, the clock and battery live in it beside the island and the
    /// screen starts right under it. Without one, they take the first row.
    var hasBand: Bool { inset >= 14 }
    var top: CGFloat { hasBand ? inset - 16 : inset }
    var statusY: CGFloat { hasBand ? ((inset - 8) / 2).rounded() : inset + 5 }
    var left: CGFloat { 8 }
    var right: CGFloat { w - 8 }
    var width: CGFloat { w - 16 }
    var full: CGRect { CGRect(x: 0, y: 0, width: w, height: h) }
    var tabTop: CGFloat { bottom - 30 }
    var cassetteH: CGFloat { (width * 0.64).rounded() }
}

/// One pixel screen: what it shows, and what a finger on it does.
final class Pane: ObservableObject {
    @Published var screen: Screen
    var onEditName: (() -> Void)?

    private var canvas = PixelCanvas()
    private var f = Frame(w: 136, h: 296, inset: 0, bottom: 296)
    private let m = Machine.shared
    private var rot: Double = 0
    private var lastFrame = CACurrentMediaTime()
    private let haptic = UISelectionFeedbackGenerator()
    private static let clockFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm"; return f }()

    private var downPoint: CGPoint?
    private var lastPoint: CGPoint = .zero
    private var moved = false
    private var gesture: Kind = .none
    private var press = Press()
    private var pressTimer: Timer?
    private var windCarry: CGFloat = 0
    private var fling: CGFloat = 0
    private var lastDy: CGFloat = 0
    var tool: Tool = .draw
    private var inkWorking: UIImage?

    private enum Kind { case none, wind, scroll, paint, hold, scrub }

    init(screen: Screen) { self.screen = screen }

    /// Canvas pixels are the layout's own coordinates.
    func layoutPoint(_ canvasPoint: CGPoint) -> CGPoint { canvasPoint }

    func render(at t: Double, width: Int, height: Int, safeTop: Int, safeBottom: Int) -> CGImage? {
        if canvas.width != width || canvas.height != height { canvas = PixelCanvas(width: width, height: height) }
        f = Frame(w: CGFloat(width), h: CGFloat(height), inset: CGFloat(safeTop), bottom: CGFloat(height - safeBottom))
        let now = CACurrentMediaTime()
        let dt = min(0.12, now - lastFrame)
        lastFrame = now
        if !UIAccessibility.isReduceMotionEnabled { rot += m.rate * dt * 5 }
        if fling != 0 {
            scrollBy(fling)
            fling *= 0.85
            if abs(fling) < 0.3 { fling = 0 }
        }
        return canvas.frame(offset: .zero, oled: m.background == .oled) { c, _ in
            switch screen {
            case .deck: drawDeck(c, t)
            case .shelf: drawShelf(c, t)
            case .clips: drawClips(c, t)
            case .label: drawLabel(c, t)
            case .edit: drawEdit(c, t)
            case .settings: drawSettings(c, t)
            }
        }
    }

    // MARK: shared pieces

    private func chrome(_ c: CGContext, _ t: Double) {
        let y = f.statusY
        let clock = Self.clockFormat.string(from: Date())
        if f.hasBand { Pix.text(clock, (f.w * 0.2).rounded(), y, Ink.cream, font: Pix.bold, align: .center) }
        else { Pix.text(clock, f.left + 1, y, Ink.cream) }
        let level = UIDevice.current.batteryLevel
        let bx = f.hasBand ? (f.w * 0.8 - 7).rounded() : f.right - 17
        Pix.fill(c, bx, y + 1, 14, 7, Ink.cream); Pix.fill(c, bx + 14, y + 3, 1, 3, Ink.cream)
        Pix.fill(c, bx + 1, y + 2, 12, 5, Ink.ink)
        let cells = level < 0 ? 12 : max(1, Int((Float(12) * level).rounded()))
        Pix.fill(c, bx + 1, y + 2, CGFloat(cells), 5, level >= 0 && level < 0.2 ? Ink.red : Ink.teal)
        if m.recording && screen != .deck {
            let cx = f.w / 2
            let y = f.top + 8
            Pix.rrect(c, cx - 32, y - 2, 64, 11, 6, Ink.ink)
            if Int(t / 0.4) % 2 == 1 { Pix.circle(c, cx - 25, y + 3.5, 2, Ink.red) }
            Pix.text("REC", cx - 20, y, Ink.red)
            Pix.text(mmss(m.recSeconds), cx + 28, y, Ink.red, align: .right)
        }
    }

    private func tabs(_ c: CGContext) {
        let y = f.tabTop
        Pix.fill(c, 0, y, f.w, f.h - y, m.blackBackground ? Ink.ink : Ink.hex(0x0c0c18))
        Pix.fill(c, 0, y, f.w, 1, Ink.blue2)
        let slot = f.w / CGFloat(Screen.tabs.count)
        for (n, s) in Screen.tabs.enumerated() {
            let cx = (slot * CGFloat(n) + slot / 2).rounded(), on = s == screen
            Pix.text(s.title, cx, y + 6, on ? Ink.yellow : Ink.grey, font: on ? Pix.bold : Pix.regular, align: .center)
            if on { Pix.fill(c, cx - 9, y + 16, 18, 1, Ink.yellow) }
        }
    }

    private func mmss(_ s: Double) -> String { let v = Int(s); return String(format: "%02d:%02d", v / 60, v % 60) }

    private func pill(_ c: CGContext, _ r: CGRect, _ label: String, _ bg: UIColor, _ fg: UIColor) {
        Pix.rrect(c, r.minX, r.minY, r.width, r.height, 6, bg)
        Pix.text(label, r.midX, r.minY + 3, fg, align: .center)
    }

    private var headerPill: CGRect { CGRect(x: f.right - 34, y: f.top + 22, width: 34, height: 13) }
    private var bgPill: CGRect { CGRect(x: f.right - 34 - 4 - 15, y: f.top + 22, width: 15, height: 13) }

    // MARK: deck

    private var cas: CGRect { CGRect(x: f.left, y: f.top + 50, width: f.width, height: f.cassetteH) }
    private var transport: CGRect { CGRect(x: f.left, y: f.tabTop - 48, width: f.width, height: 40) }
    /// Four tape-deck keys across the width: ◀◀  ▶  ●  ▶▶.
    private func key(_ i: Int) -> CGRect {
        let gap: CGFloat = 3
        let w = ((transport.width - 10 - gap * 3) / 4).rounded(.down)
        let x0 = transport.minX + (transport.width - (w * 4 + gap * 3)) / 2
        return CGRect(x: (x0 + CGFloat(i) * (w + gap)).rounded(), y: transport.minY + 4, width: w, height: transport.height - 8)
    }
    private var heldKey: Int?
    private var keyDownAt: Double = 0
    private var keyTimer: Timer?

    private func drawDeck(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.hex(0x283870), Ink.hex(0x141428), Ink.hex(0x1c2c40), in: f.full)
        if !m.blackBackground { Pix.glow(c, CGPoint(x: cas.midX, y: cas.midY), f.w * 0.6, Ink.teal.withAlphaComponent(0.6)) }
        chrome(c, t)
        guard let tape = m.tape else { return }
        let top = f.top
        Pix.text("ON THE MACHINE", f.left, top + 22, Ink.mint)
        Pix.marquee(c, tape.name.uppercased(), f.left, top + 33, maxW: headerPill.minX - f.left - 4, Ink.cream, font: Pix.bold, t: t)
        if m.recording {
            if Int(t / 0.4) % 2 == 1 { Pix.circle(c, f.right - 24, top + 29, 3, Ink.red) }
            Pix.text("REC", f.right, top + 25, Ink.red, font: Pix.bold, align: .right)
        } else {
            pill(c, headerPill, "SHELF", Ink.blue2, Ink.cream)
        }
        let tl = m.timeline
        Cassette.draw(c, cas.minX, cas.minY, cas.width, cas.height, name: tape.name, label: tape.label, ink: m.inks[tape.id],
                      fraction: tl.fraction(m.position), rot: rot, t: t)

        var y = cas.maxY + 11
        if m.recording {
            Pix.text("RECORDING", f.left, y, Ink.red, font: Pix.bold)
            Pix.marquee(c, mmss(m.recSeconds) + (m.mark != nil ? "  OVER THE TAPE" : "  ONTO THE END"), f.left, y + 11, maxW: f.width, Ink.grey, t: t)
        } else if let i = tl.clipIndex(at: m.position) {
            let clip = tl.clips[i]
            Pix.marquee(c, clip.name.uppercased(), f.left, y, maxW: f.width, Ink.cream, font: Pix.bold, t: t)
            Pix.marquee(c, Naming.short(clip.date), f.left, y + 11, maxW: f.width, Ink.grey, t: t)
        } else {
            Pix.text("EMPTY TAPE", f.left, y, Ink.cream, font: Pix.bold)
            Pix.marquee(c, "HOLD THE TAPE TO RECORD", f.left, y + 11, maxW: f.width, Ink.grey, t: t)
        }
        y += 26
        if !tl.isEmpty {
            for seg in tl.segments {
                let x0 = f.left + (CGFloat(seg.start / tl.total) * f.width).rounded()
                let x1 = f.left + (CGFloat(seg.end / tl.total) * f.width).rounded()
                let take = tl.clips[seg.clip].isTake
                Pix.fill(c, x0, y, max(1, x1 - x0 - 1), 9, take ? Ink.red : Ink.clipColors[seg.clip % 6])
                if take { Pix.fill(c, x0, y, max(1, x1 - x0 - 1), 2, Ink.pink) }
            }
            if let mk = m.mark {
                let mx = f.left + (CGFloat(tl.fraction(mk)) * (f.width - 1)).rounded()
                Pix.fill(c, mx, y - 5, 1, 17, Ink.yellow); Pix.fill(c, mx, y - 5, 4, 3, Ink.yellow)
            }
            let hx = f.left + (CGFloat(tl.fraction(m.position)) * (f.width - 1)).rounded()
            Pix.fill(c, hx, y - 3, 1, 15, Ink.cream); Pix.fill(c, hx - 1, y - 4, 3, 2, Ink.cream)
        } else {
            Pix.fill(c, f.left, y, f.width, 9, Ink.blue)
        }
        barY = y
        y += 15
        drawScrubber(c, y)
        y += 14
        Pix.text(Pix.clock(m.position), f.left, y, Ink.cream)
        let r = m.rate
        Pix.text((r < 0 ? "-" : "") + String(format: "%.1fX", abs(r)), f.w / 2, y, abs(r) > 1.1 ? Ink.yellow : Ink.mint, align: .center)
        Pix.text(Pix.clock(tl.total), f.right, y, Ink.grey, align: .right)

        // Level meter just above the transport; the space between grows on taller screens.
        let bars = Int((f.width - 16) / 4)
        let mx = (f.w - CGFloat(bars * 4)) / 2
        let base = transport.minY - 11
        for i in 0..<bars {
            var h: CGFloat = 1
            let wobble: Double = abs(sin(t / 0.14 + Double(i) * 1.7))
            if m.recording {
                let lv: Double = Double(min(1, m.level * 6))
                let jitter: Double = 0.6 + 0.4 * abs(sin(t * 7 + Double(i)))
                h = CGFloat(1 + (lv * 11 * jitter).rounded())
            } else if r != 0 {
                let gain: Double = abs(r) > 1.2 ? 1 : 0.75
                h = CGFloat(2 + (wobble * 10 * gain).rounded())
            }
            let frac = Double(i) / Double(max(1, bars - 1))
            Pix.fill(c, mx + CGFloat(i * 4), base - h, 3, h, frac > 0.84 ? Ink.red : frac > 0.68 ? Ink.yellow : Ink.teal)
        }

        drawKeys(c)
        tabs(c)
    }

    // The scrubber: a track under the tape bar with a knob you drag to any point on the tape.
    private var barY: CGFloat = 0
    private var scrubRect: CGRect { CGRect(x: f.left - 4, y: barY + 11, width: f.width + 8, height: 18) }

    /// The shuttle: its own control, not a map of the tape. Push the knob left or right and
    /// the tape winds that way, faster the further you push, until you let go; then the knob
    /// springs back to the middle.
    private var shuttleOffset: CGFloat = 0
    private var shuttleStartX: CGFloat = 0
    private var shuttleStep = 0
    private var shuttleMax: CGFloat { max(20, (f.width / 2 - 14).rounded()) }

    private func drawScrubber(_ c: CGContext, _ y: CGFloat) {
        let cx = (f.left + f.width / 2).rounded()
        let held = gesture == .scrub
        Pix.fill(c, f.left + 12, y + 3, f.width - 24, 2, Ink.blue)
        // Speed marks, denser toward the ends.
        for k in 1...4 {
            let d = (shuttleMax * CGFloat(k) / 4).rounded()
            Pix.fill(c, cx - d, y + (k == 4 ? 0 : 2), 1, k == 4 ? 8 : 4, Ink.blue2)
            Pix.fill(c, cx + d, y + (k == 4 ? 0 : 2), 1, k == 4 ? 8 : 4, Ink.blue2)
        }
        Pix.fill(c, cx, y + 1, 1, 6, Ink.grey)
        let arrow: UIColor = held ? Ink.yellow : Ink.grey
        Pix.poly(c, [CGPoint(x: f.left, y: y + 4), CGPoint(x: f.left + 5, y: y), CGPoint(x: f.left + 5, y: y + 8)], shuttleOffset < 0 ? arrow : Ink.blue2)
        Pix.poly(c, [CGPoint(x: f.left + 5, y: y + 4), CGPoint(x: f.left + 10, y: y), CGPoint(x: f.left + 10, y: y + 8)], shuttleOffset < 0 ? arrow : Ink.blue2)
        Pix.poly(c, [CGPoint(x: f.right, y: y + 4), CGPoint(x: f.right - 5, y: y), CGPoint(x: f.right - 5, y: y + 8)], shuttleOffset > 0 ? arrow : Ink.blue2)
        Pix.poly(c, [CGPoint(x: f.right - 5, y: y + 4), CGPoint(x: f.right - 10, y: y), CGPoint(x: f.right - 10, y: y + 8)], shuttleOffset > 0 ? arrow : Ink.blue2)
        let kx = cx + shuttleOffset.rounded()
        if held && shuttleOffset != 0 {
            let a = min(cx, kx), b = max(cx, kx)
            Pix.fill(c, a, y + 3, b - a, 2, Ink.yellow)
        }
        Pix.fill(c, kx - 4, y - 2, 9, 12, Ink.dark)
        Pix.fill(c, kx - 3, y - 1, 7, 10, held ? Ink.yellow : Ink.cream)
        Pix.fill(c, kx - 1, y + 1, 1, 6, Ink.dark); Pix.fill(c, kx + 1, y + 1, 1, 6, Ink.dark)
    }

    private func shuttle(to x: CGFloat) {
        shuttleOffset = max(-shuttleMax, min(shuttleMax, x - shuttleStartX))
        let mag = abs(shuttleOffset) / shuttleMax
        guard abs(shuttleOffset) >= 3 else {
            m.holdRate = nil
            if shuttleStep != 0 { shuttleStep = 0; haptic.selectionChanged() }
            return
        }
        // 1x at a nudge, 8x at the end, in steps you can feel.
        let speeds: [Double] = [1, 2, 4, 8]
        let step = min(speeds.count - 1, Int(mag * CGFloat(speeds.count)))
        let dir: Double = shuttleOffset > 0 ? 1 : -1
        m.holdRate = dir * speeds[step]
        let signed = (step + 1) * Int(dir)
        if signed != shuttleStep { shuttleStep = signed; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    private func shuttleRelease() {
        m.holdRate = nil
        shuttleOffset = 0
        shuttleStep = 0
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
    }

    /// Horizontal drag as wheel notches, BrightRecorder's Scrub: the tape winds at the speed
    /// of the hand, forwards or back, with a haptic tick per notch.
    private func windBy(_ dx: CGFloat, pixelsPerNotch: CGFloat) {
        windCarry += dx
        while abs(windCarry) >= pixelsPerNotch {
            let dir = windCarry > 0 ? 1 : -1
            m.notch(dir)
            haptic.selectionChanged()
            windCarry -= CGFloat(dir) * pixelsPerNotch
        }
    }

    private func scrub(to x: CGFloat) {
        let fr = Double(min(1, max(0, (x - f.left) / max(1, f.width - 1))))
        m.seek(fr * m.timeline.total)
    }

    private func drawGear(_ c: CGContext, _ r: CGRect) {
        Pix.rrect(c, r.minX, r.minY, r.width, r.height, 6, Ink.blue)
        let cx = r.midX.rounded(), cy = r.midY.rounded()
        for (dx, dy) in [(0, -4), (0, 4), (-4, 0), (4, 0), (-3, -3), (3, -3), (-3, 3), (3, 3)] {
            Pix.fill(c, cx + CGFloat(dx) - 1, cy + CGFloat(dy) - 1, 2, 2, Ink.cream)
        }
        Pix.circle(c, cx, cy, 3.5, Ink.cream)
        Pix.circle(c, cx, cy, 1.5, Ink.blue)
    }

    // MARK: settings

    private func optionRect(_ i: Int) -> CGRect { CGRect(x: f.left, y: f.top + 62 + CGFloat(i) * 26, width: f.width, height: 22) }
    private var clicksRect: CGRect { CGRect(x: f.left, y: optionRect(2).maxY + 30, width: f.width, height: 22) }

    private func drawSettings(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.navy, Ink.hex(0x202850), Ink.blue, in: f.full)
        chrome(c, t)
        Pix.text("SETTINGS", f.left, f.top + 18, Ink.cream, font: Pix.big)
        pill(c, headerPill, "DONE", Ink.blue2, Ink.cream)
        Pix.text("BACKGROUND", f.left, f.top + 50, Ink.grey)
        for (i, b) in Machine.Background.allCases.enumerated() {
            let r = optionRect(i)
            let on = m.background == b
            Pix.rrect(c, r.minX - 1, r.minY - 1, r.width + 2, r.height + 2, 5, on ? Ink.yellow : Ink.dark)
            Pix.rrect(c, r.minX, r.minY, r.width, r.height, 4, Ink.blue)
            let sw = CGRect(x: r.minX + 4, y: r.minY + 4, width: 22, height: 14)
            switch b {
            case .sky:
                Pix.vgrad(c, sw, [(0, Ink.hex(0x283870)), (1, Ink.hex(0x141428))])
                Pix.fill(c, sw.minX + 5, sw.minY + 3, 1, 1, Ink.cream); Pix.fill(c, sw.minX + 15, sw.minY + 8, 1, 1, Ink.yellow)
            case .black: Pix.fill(c, sw.minX, sw.minY, sw.width, sw.height, Ink.ink)
            case .oled: Pix.fill(c, sw.minX, sw.minY, sw.width, sw.height, Ink.ink)
            }
            Pix.text(b.title, sw.maxX + 6, r.minY + 7, Ink.cream, font: on ? Pix.bold : Pix.regular)
            let note = b == .sky ? "STARS" : b == .black ? "BLUE-BLACK" : "PIXELS OFF"
            Pix.text(note, r.maxX - 5, r.minY + 7, Ink.grey, align: .right)
        }
        Pix.text("KEYS", f.left, clicksRect.minY - 12, Ink.grey)
        let kr = clicksRect
        Pix.rrect(c, kr.minX, kr.minY, kr.width, kr.height, 4, Ink.blue)
        Pix.text("CLICK SOUND", kr.minX + 6, kr.minY + 7, Ink.cream)
        let sw = CGRect(x: kr.maxX - 30, y: kr.minY + 5, width: 24, height: 12)
        Pix.rrect(c, sw.minX, sw.minY, sw.width, sw.height, 6, m.keyClicks ? Ink.teal : Ink.dark)
        Pix.circle(c, m.keyClicks ? sw.maxX - 6 : sw.minX + 6, sw.midY, 4, Ink.cream)
        Pix.marquee(c, "\(PlaceBook.entries.count) PLACES YOU'VE NAMED", f.left, kr.maxY + 14, maxW: f.width, Ink.grey, t: t)
        tabs(c)
    }

    private func settingsDown(_ p: CGPoint) {
        if headerPill.insetBy(dx: -4, dy: -4).contains(p) { switchTo(.shelf); return }
        for (i, b) in Machine.Background.allCases.enumerated() where optionRect(i).contains(p) {
            m.background = b
            UISelectionFeedbackGenerator().selectionChanged()
        }
        if clicksRect.contains(p) { m.keyClicks.toggle() }
    }

    private func drawKeys(_ c: CGContext) {
        let tp = transport
        Pix.rrect(c, tp.minX, tp.minY, tp.width, tp.height, 6, Ink.ink)
        Pix.fill(c, tp.minX + 4, tp.minY + 2, tp.width - 8, 1, Ink.blue)
        let down: [Bool] = [
            heldKey == 0 || (m.holdRate ?? 0) < 0,
            m.playing || heldKey == 1,
            m.recording || heldKey == 2,
            heldKey == 3 || (m.holdRate ?? 0) > 0
        ]
        for i in 0..<4 {
            let r = key(i)
            let sunk: CGFloat = down[i] ? 3 : 0
            let lip: CGFloat = down[i] ? 2 : 5
            let faceH = r.height - 5
            let face = CGRect(x: r.minX, y: r.minY + sunk, width: r.width, height: faceH)
            Pix.rrect(c, r.minX, face.maxY - 2, r.width, lip + 2, 3, Ink.dark)
            let top: UIColor = i == 2 && m.recording ? Ink.red : (down[i] ? Ink.tan : Ink.cream)
            Pix.rrect(c, face.minX, face.minY, face.width, face.height, 3, top)
            if !down[i] { Pix.fill(c, face.minX + 3, face.minY + 1, face.width - 6, 1, UIColor.white.withAlphaComponent(0.6)) }
            let cx = face.midX.rounded(), cy = face.midY.rounded()
            let icon: UIColor = i == 2 && m.recording ? Ink.cream : Ink.dark
            switch i {
            case 0: Pix.tri(c, cx - 1, cy, -1, icon); Pix.tri(c, cx + 5, cy, -1, icon)
            case 1:
                if m.playing { Pix.fill(c, cx - 4, cy - 5, 3, 10, icon); Pix.fill(c, cx + 2, cy - 5, 3, 10, icon) }
                else { Pix.tri(c, cx - 3, cy, 1.3, icon) }
            case 2: Pix.circle(c, cx, cy, 5, i == 2 && m.recording ? Ink.cream : Ink.red)
            default: Pix.tri(c, cx - 5, cy, 1, icon); Pix.tri(c, cx + 1, cy, 1, icon)
            }
        }
    }

    // MARK: shelf

    private struct ShelfSlot { let index: Int; let y: CGFloat; let front: Bool; let step: CGFloat }

    private func shelfLayout() -> [ShelfSlot] {
        var order = m.tapes.indices.filter { $0 != m.current }
        if m.tapes.indices.contains(m.current) { order.append(m.current) }
        let n = order.count
        let y0 = f.top + 56
        let room = f.tabTop - 10 - f.cassetteH - y0
        let step: CGFloat = n > 1 ? max(14, min(44, (room / CGFloat(n - 1)).rounded(.down))) : 0
        return order.enumerated().map { k, i in ShelfSlot(index: i, y: y0 + CGFloat(k) * step, front: k == n - 1, step: step) }
    }

    private func drawShelf(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.navy, Ink.hex(0x202850), Ink.blue, in: f.full)
        chrome(c, t)
        Pix.text("SHELF", f.left, f.top + 18, Ink.cream, font: Pix.big)
        if !m.recording { pill(c, headerPill, "+ NEW", Ink.teal, Ink.cream) }
        drawGear(c, bgPill)
        Pix.marquee(c, "TAP A TAPE TO LOAD IT", f.left, f.top + 40, maxW: f.width, Ink.grey, t: t)
        let h = f.cassetteH
        for slot in shelfLayout() {
            let tape = m.tapes[slot.index]
            Pix.rrect(c, f.left + 1, slot.y + 3, f.width + 1, h + 1, 6, Ink.ink.withAlphaComponent(0.7))
            let frac = slot.front ? m.timeline.fraction(m.position) : 0.5
            Cassette.draw(c, f.left, slot.y, f.width, h, name: tape.name, label: tape.label, ink: m.inks[tape.id], fraction: frac,
                          rot: slot.front ? rot : 0, duration: Pix.short(m.totalSeconds(tape)), t: t + Double(slot.index))
            if slot.front && Int(t / 0.45) % 2 == 1 {
                let my = slot.y + h / 2
                Pix.poly(c, [CGPoint(x: 1, y: my - 4), CGPoint(x: 5, y: my), CGPoint(x: 1, y: my + 4)], Ink.yellow)
            }
        }
        tabs(c)
    }

    // MARK: clips

    private var topV: CGFloat { f.top + 44 }
    private var botV: CGFloat { f.tabTop - 26 }
    private var headY: CGFloat { ((topV + botV) / 2).rounded() }
    private var playBar: CGRect { CGRect(x: f.left, y: botV + 5, width: f.width, height: 16) }

    /// One row per stretch of tape you can hear: covered parts aren't listed.
    private struct Row { let index: Int; let clip: Int; let y: CGFloat; let h: CGFloat; let seconds: Double }

    private func rows() -> [Row] {
        var y: CGFloat = 0
        return m.timeline.segments.enumerated().map { i, sg in
            let h = max(30, (CGFloat(sg.length / 60) * 2.4).rounded())
            defer { y += h + 2 }
            return Row(index: i, clip: sg.clip, y: y, h: h, seconds: sg.length)
        }
    }

    private func posToY(_ pos: Double) -> CGFloat {
        let tl = m.timeline, rs = rows()
        guard let si = tl.segmentIndex(at: pos), rs.indices.contains(si) else { return 0 }
        let r = rs[si]
        let into = min(max(0, pos - tl.segments[si].start), r.seconds)
        return r.y + CGFloat(r.seconds > 0 ? into / r.seconds : 0) * r.h
    }

    private func yToPos(_ y: CGFloat) -> Double {
        let tl = m.timeline, rs = rows()
        guard let last = rs.last else { return 0 }
        for r in rs where y <= r.y + r.h + 1 || r.index == last.index {
            let fr = Double(min(1, max(0, (y - r.y) / r.h)))
            return min(tl.total, tl.start(of: r.index) + fr * r.seconds)
        }
        return tl.total
    }

    private func scrollBy(_ dy: CGFloat) { m.seek(yToPos(posToY(m.position) + dy)) }

    private func drawClips(_ c: CGContext, _ t: Double) {
        let bg = m.blackBackground ? Ink.ink : Ink.hex(0x141428)
        Sky.draw(c, t, bg, Ink.navy, bg, in: f.full)
        chrome(c, t)
        guard let tape = m.tape else { return }
        let rs = rows(), off = headY - posToY(m.position)
        let cardX: CGFloat = 24, cardW = f.right - cardX
        c.saveGState(); c.clip(to: CGRect(x: 0, y: topV, width: f.w, height: botV - topV))
        for r in rs {
            let y = (off + r.y).rounded()
            if y > botV || y + r.h < topV { continue }
            let clip = m.timeline.clips[r.clip]
            let under = headY >= y && headY < y + r.h + 2
            Pix.fill(c, f.left, y, 12, r.h, clip.isTake ? Ink.red : Ink.clipColors[r.clip % 6])
            var yy = y + 3
            while yy < y + r.h - 2 { Pix.fill(c, f.left + 5, yy, 2, 2, Ink.dark); yy += 6 }
            Pix.rrect(c, cardX, y, cardW, r.h, 4, under ? Ink.cream : Ink.blue)
            let tc = under ? Ink.dark : Ink.cream, mc = under ? Ink.brown : Ink.grey
            Pix.marquee(c, clip.name.uppercased(), cardX + 4, y + 4, maxW: cardW - 8, tc, font: Pix.bold, t: t + Double(r.index))
            let dw = Pix.text(Pix.short(clip.seconds), f.right - 4, y + 14, mc, align: .right)
            Pix.marquee(c, Naming.short(clip.date), cardX + 4, y + 14, maxW: cardW - 12 - ceil(dw), mc, t: t)
            if r.h >= 46 {
                let n = Int((cardW - 8) / 4)
                for j in 0..<n {
                    let seedV: Double = Double(j * 13 + r.index * 7)
                    let bh: CGFloat = 1 + CGFloat(Int(abs(sin(seedV)) * 5))
                    Pix.fill(c, cardX + 4 + CGFloat(j * 4), y + r.h - 3 - bh, 3, bh, under ? Ink.brown : Ink.blue2)
                }
            }
        }
        c.restoreGState()
        if rs.isEmpty { Pix.marquee(c, "NOTHING ON THIS TAPE YET", f.left, headY - 12, maxW: f.width, Ink.grey, t: t) }
        Pix.vgrad(c, CGRect(x: 0, y: topV, width: f.w, height: 14), [(0, bg), (1, bg.withAlphaComponent(0))])
        Pix.vgrad(c, CGRect(x: 0, y: botV - 14, width: f.w, height: 14), [(0, bg.withAlphaComponent(0)), (1, bg)])
        Pix.fill(c, 4, headY, f.w - 8, 1, Ink.red)
        Pix.poly(c, [CGPoint(x: 0, y: headY - 4), CGPoint(x: 5, y: headY), CGPoint(x: 0, y: headY + 4)], Ink.cream)
        Pix.poly(c, [CGPoint(x: f.w, y: headY - 4), CGPoint(x: f.w - 5, y: headY), CGPoint(x: f.w, y: headY + 4)], Ink.cream)
        let clock = Pix.clock(m.position)
        let pw = ceil(Pix.width(clock))
        Pix.marquee(c, tape.name.uppercased(), f.left, f.top + 20, maxW: f.width - pw - 4, Ink.cream, font: Pix.bold, t: t)
        Pix.text(clock, f.right, f.top + 20, Ink.yellow, align: .right)
        Pix.text("\(rs.count) CLIPS", f.left, f.top + 31, Ink.grey)
        Pix.text("DRAG TO WIND", f.right, f.top + 31, Ink.blue2, align: .right)
        let pb = playBar
        Pix.rrect(c, pb.minX, pb.minY, pb.width, pb.height, 8, m.playing ? Ink.blue2 : Ink.teal)
        if m.playing { Pix.fill(c, pb.minX + 10, pb.minY + 4, 2, 8, Ink.cream); Pix.fill(c, pb.minX + 14, pb.minY + 4, 2, 8, Ink.cream) }
        else { Pix.poly(c, [CGPoint(x: pb.minX + 10, y: pb.minY + 4), CGPoint(x: pb.minX + 16, y: pb.minY + 8), CGPoint(x: pb.minX + 10, y: pb.minY + 12)], Ink.cream) }
        Pix.text(m.playing ? "PLAYING" : "PLAY FROM HERE", pb.midX + 6, pb.minY + 4, Ink.cream, align: .center)
        if case .clip = m.editing {
            let box = CGRect(x: f.left, y: headY - 20, width: f.width, height: 30)
            Pix.rrect(c, box.minX - 1, box.minY - 1, box.width + 2, box.height + 2, 5, Ink.yellow)
            Pix.rrect(c, box.minX, box.minY, box.width, box.height, 4, Ink.cream)
            Pix.text("NAME THIS PLACE", box.minX + 4, box.minY + 4, Ink.brown)
            let w = Pix.tail(c, m.nameDraft.uppercased(), box.minX + 4, box.minY + 16, maxW: box.width - 10, Ink.dark, font: Pix.bold)
            if Int(t / 0.5) % 2 == 1 { Pix.fill(c, min(box.maxX - 4, box.minX + 5 + ceil(w)), box.minY + 15, 1, 9, Ink.dark) }
        }
        tabs(c)
    }

    // MARK: label editor

    private var editCas: CGRect { CGRect(x: f.left, y: f.top + 44, width: f.width, height: f.cassetteH) }
    private var labelRect: CGRect { Cassette.labelRect(editCas.minX, editCas.minY, editCas.width, editCas.height) }
    private var labelTop: CGFloat { editCas.maxY + 7 }
    private var nameBox: CGRect { CGRect(x: f.left, y: labelTop + 9, width: f.width, height: 15) }
    private var swatchSize: CGFloat { min(22, (f.width / 6 - 2).rounded(.down)) }
    private func swatch(_ i: Int) -> CGRect {
        let step = (f.width + 2) / 6
        return CGRect(x: (f.left + CGFloat(i) * step).rounded(), y: labelTop + 38, width: swatchSize, height: swatchSize)
    }
    private func pairRect(_ i: Int) -> CGRect {
        let s = swatch(i)
        return CGRect(x: s.minX, y: s.maxY + 16, width: swatchSize, height: 12)
    }
    private var toolsY: CGFloat { pairRect(0).maxY + 9 }
    private func toolRect(_ i: Int) -> CGRect {
        let w = ((f.width - 8) / 3).rounded(.down)
        return CGRect(x: f.left + CGFloat(i) * (w + 4), y: toolsY, width: w, height: 15)
    }
    private let tools: [(Tool?, String)] = [(.draw, "DRAW"), (.erase, "ERASE"), (nil, "CLEAR")]

    private func drawLabel(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.hex(0x202850), Ink.navy, Ink.hex(0x141428), in: f.full)
        chrome(c, t)
        guard let tape = m.tape else { return }
        Pix.text("LABEL", f.left, f.top + 18, Ink.cream, font: Pix.big)
        pill(c, headerPill, "DONE", Ink.blue2, Ink.cream)
        let name = m.editing == .tape && !m.nameDraft.isEmpty ? m.nameDraft : tape.name
        Cassette.draw(c, editCas.minX, editCas.minY, editCas.width, editCas.height, name: name, label: tape.label,
                      ink: inkWorking ?? m.inks[tape.id], fraction: m.timeline.fraction(m.position), rot: rot, t: t)
        Pix.text("NAME", f.left, labelTop, Ink.grey)
        let nb = nameBox
        Pix.rrect(c, nb.minX, nb.minY, nb.width, nb.height, 3, Ink.cream)
        let w = Pix.tail(c, name.uppercased(), nb.minX + 4, nb.minY + 4, maxW: nb.width - 10, Ink.dark, font: Pix.bold)
        if Int(t / 0.5) % 2 == 1 { Pix.fill(c, min(nb.maxX - 4, nb.minX + 5 + ceil(w)), nb.minY + 3, 1, 9, Ink.dark) }
        Pix.text("PATTERN", f.left, labelTop + 30, Ink.grey)
        for (i, k) in Pattern.allCases.enumerated() {
            let r = swatch(i)
            Pix.fill(c, r.minX - 1, r.minY - 1, r.width + 2, r.height + 2, k == tape.label.pattern ? Ink.yellow : Ink.dark)
            Cassette.pattern(c, k, tape.label.pair, r)
        }
        Pix.text("COLORS", f.left, swatch(0).maxY + 5, Ink.grey)
        for (i, p) in Ink.pairs.enumerated() {
            let r = pairRect(i)
            Pix.fill(c, r.minX - 1, r.minY - 1, r.width + 2, r.height + 2, i == tape.label.pair ? Ink.yellow : Ink.dark)
            let half = (r.width / 2).rounded()
            Pix.fill(c, r.minX, r.minY, half, r.height, p.0); Pix.fill(c, r.minX + half, r.minY, r.width - half, r.height, p.1)
        }
        for (i, item) in tools.enumerated() {
            let r = toolRect(i)
            let on = item.0 != nil && item.0 == tool
            Pix.rrect(c, r.minX, r.minY, r.width, r.height, 4, on ? Ink.yellow : Ink.blue)
            Pix.text(item.1, r.midX, r.minY + 4, on ? Ink.dark : Ink.cream, align: .center)
        }
        let hint = tool == .draw ? "DRAW ON THE LABEL" : tool == .erase ? "RUB OUT A LINE" : "TAP THE NAME TO RENAME"
        let hy = toolsY + 24
        if hy + 10 < f.tabTop { Pix.marquee(c, hint, f.left, hy, maxW: f.width, Ink.blue2, t: t) }
        tabs(c)
    }

    // MARK: edit — the tape as tracks

    /// Pixels per second of tape, and the steps + and − move through.
    private static let zooms: [CGFloat] = [0.5, 1, 2, 4, 8, 16, 32, 64]
    private var zoomIndex = 4
    private var zoom: CGFloat { Pane.zooms[zoomIndex] }
    private var layersMode = false
    private var selectedClip: Int?
    private var editDrag: EditDrag = .none
    private enum EditDrag { case none, pan, trimIn, trimOut }

    private var laneTop: CGFloat { f.top + 58 }
    private var trackLaneH: CGFloat { max(48, min(90, ((f.tabTop - 48 - 70) - laneTop) * 0.55)).rounded() }
    private var baseLaneH: CGFloat { layersMode ? 36 : trackLaneH }
    private var takeLaneH: CGFloat { 20 }
    private var takeLayers: [Timeline.Segment] { m.timeline.layers.filter { m.timeline.clips[$0.clip].isTake } }
    private var lanesBottom: CGFloat {
        layersMode ? laneTop + baseLaneH + CGFloat(min(takeLayers.count, maxTakeLanes)) * (takeLaneH + 3) : laneTop + trackLaneH
    }
    private var maxTakeLanes: Int { max(1, Int(((f.tabTop - 48 - 64) - (laneTop + baseLaneH)) / (takeLaneH + 3))) }
    private var modePill: CGRect { CGRect(x: f.right - 46, y: f.top + 22, width: 46, height: 13) }
    private var zoomOut: CGRect { CGRect(x: f.right - 32, y: lanesBottom + 8, width: 14, height: 13) }
    private var zoomIn: CGRect { CGRect(x: f.right - 14, y: lanesBottom + 8, width: 14, height: 13) }
    private var playheadX: CGFloat { (f.w / 2).rounded() }

    /// The editor's playhead on the tape. While a clip's original plays alone, its file
    /// position is shown where that clip sits.
    private var editPosition: Double {
        if let s = m.solo, let lay = m.timeline.layers.first(where: { $0.clip == s }) {
            return lay.start + (m.soloPosition - m.timeline.clips[s].trimIn)
        }
        return m.position
    }

    private func xFor(_ t: Double) -> CGFloat { playheadX + CGFloat(t - editPosition) * zoom }
    private func tFor(_ x: CGFloat) -> Double { editPosition + Double((x - playheadX) / zoom) }

    private func waveColumn(_ c: CGContext, x: CGFloat, mid: CGFloat, half: CGFloat, peak: Float, color: UIColor) {
        let v = CGFloat(min(1, sqrt(Double(peak)) * 1.15))
        let h = max(1, (v * half).rounded())
        Pix.fill(c, x, mid - h, 1, h * 2, color)
    }

    private func drawEdit(_ c: CGContext, _ t: Double) {
        let bg = m.blackBackground ? Ink.ink : Ink.hex(0x141428)
        Sky.draw(c, t, bg, Ink.navy, bg, in: f.full)
        chrome(c, t)
        guard let tape = m.tape else { return }
        let tl = m.timeline
        Pix.text("EDIT", f.left, f.top + 18, Ink.cream, font: Pix.big)
        pill(c, modePill, layersMode ? "LAYERS" : "TRACK", layersMode ? Ink.purple : Ink.blue2, Ink.cream)
        Pix.marquee(c, tape.name.uppercased(), f.left + 44, f.top + 24, maxW: modePill.minX - f.left - 48, Ink.grey, t: t)
        Pix.text(clock10(editPosition), playheadX, f.top + 40, m.solo != nil ? Ink.purple : Ink.yellow, align: .center)

        // Ruler: a tick every N seconds, N chosen so ticks sit ~24 px apart.
        let rulerY = laneTop - 7
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let step = steps.first { CGFloat($0) * zoom >= 24 } ?? 3600
        var tick = (tFor(0) / step).rounded(.down) * step
        while xFor(tick) < f.w {
            let x = xFor(tick).rounded()
            if tick >= 0 && tick <= tl.total { Pix.fill(c, x, rulerY, 1, 4, Ink.blue2) }
            tick += step
        }

        c.saveGState(); c.clip(to: CGRect(x: 0, y: laneTop, width: f.w, height: lanesBottom - laneTop))
        if layersMode { drawLayers(c, t) } else { drawTrack(c, t) }
        c.restoreGState()

        // Mark, and the take being recorded now.
        if let mk = m.mark {
            let mx = xFor(mk).rounded()
            if m.recording {
                let x1 = xFor(mk + m.recSeconds).rounded()
                Pix.fill(c, mx, laneTop, max(1, x1 - mx), lanesBottom - laneTop, Ink.red.withAlphaComponent(0.55))
            }
            Pix.fill(c, mx, laneTop - 8, 1, lanesBottom - laneTop + 8, Ink.yellow)
            Pix.fill(c, mx + 1, laneTop - 8, 5, 4, Ink.yellow)
        }
        // Playhead, fixed in the middle; the tape moves under it.
        Pix.fill(c, playheadX, laneTop - 3, 1, lanesBottom - laneTop + 6, Ink.cream)
        Pix.poly(c, [CGPoint(x: playheadX - 3, y: laneTop - 6), CGPoint(x: playheadX + 4, y: laneTop - 6), CGPoint(x: playheadX, y: laneTop - 2)], Ink.cream)

        // Zoom, and what's selected.
        pill(c, zoomOut, "-", Ink.blue, Ink.cream)
        pill(c, zoomIn, "+", Ink.blue, Ink.cream)
        var y = lanesBottom + 10
        if let i = selectedClip, tl.clips.indices.contains(i) {
            let clip = tl.clips[i]
            Pix.marquee(c, clip.name.uppercased(), f.left, y, maxW: zoomOut.minX - f.left - 4, clip.isTake ? Ink.pink : Ink.cream, font: Pix.bold, t: t)
            y += 11
            Pix.text("IN " + clock10(clip.trimIn), f.left, y, Ink.mint)
            Pix.text("OUT " + clock10(clip.outPoint), f.right, y, Ink.mint, align: .right)
            y += 10
            let what = clip.isTake ? "TAKE AT " + clock10(clip.overdubAt ?? 0) : "FILE " + clock10(clip.seconds)
            Pix.marquee(c, what + "  ·  DRAG THE EDGES TO TRIM", f.left, y, maxW: f.width, Ink.grey, t: t)
        } else {
            Pix.marquee(c, "TAP A CLIP TO SELECT IT", f.left, y, maxW: zoomOut.minX - f.left - 4, Ink.grey, t: t)
            y += 11
            Pix.marquee(c, m.mark == nil ? "MARK SETS WHERE ● RECORDS OVER" : "● RECORDS OVER FROM THE MARK", f.left, y, maxW: f.width, Ink.grey, t: t)
        }
        drawEditKeys(c)
        tabs(c)
    }

    /// Track mode: only what you'd hear. Takes are red; the selected clip is cream.
    private func drawTrack(_ c: CGContext, _ t: Double) {
        let tl = m.timeline
        let mid = (laneTop + trackLaneH / 2).rounded(), half = trackLaneH / 2 - 3
        Pix.fill(c, 0, laneTop, f.w, trackLaneH, Ink.ink)
        for xi in 0..<Int(f.w) {
            let x = CGFloat(xi)
            let tt = tFor(x)
            guard tt >= 0, tt <= tl.total, let si = tl.segmentIndex(at: tt) else { continue }
            let sg = tl.segments[si], clip = tl.clips[sg.clip]
            let src = sg.src + (tt - sg.start)
            let color: UIColor = sg.clip == selectedClip ? Ink.cream : (clip.isTake ? Ink.red : Ink.clipColors[sg.clip % 6])
            waveColumn(c, x: x, mid: mid, half: half, peak: m.peak(clip.url, at: src), color: color)
        }
        for sg in tl.segments {
            let x = xFor(sg.start).rounded()
            if x >= 0 && x < f.w { Pix.fill(c, x, laneTop, 1, trackLaneH, Ink.navy) }
        }
        drawHandles(c, top: laneTop, height: trackLaneH)
    }

    /// Layers mode: every clip whole. The base tape on top with covered parts dimmed, each
    /// take on its own lane underneath where it was recorded.
    private func drawLayers(_ c: CGContext, _ t: Double) {
        let tl = m.timeline
        let base = tl.layers.filter { !tl.clips[$0.clip].isTake }
        let mid = (laneTop + baseLaneH / 2).rounded(), half = baseLaneH / 2 - 3
        Pix.fill(c, 0, laneTop, f.w, baseLaneH, Ink.ink)
        for xi in 0..<Int(f.w) {
            let x = CGFloat(xi), tt = tFor(x)
            guard let lay = base.first(where: { tt >= $0.start && tt < $0.end }) else { continue }
            let clip = tl.clips[lay.clip]
            let hidden = tl.covered(tt)
            if hidden && xi % 2 == 1 { continue }
            let color: UIColor = lay.clip == selectedClip ? Ink.cream : (hidden ? Ink.blue2 : Ink.clipColors[lay.clip % 6])
            waveColumn(c, x: x, mid: mid, half: half, peak: m.peak(clip.url, at: lay.src + (tt - lay.start)), color: color)
        }
        for (k, lay) in takeLayers.prefix(maxTakeLanes).enumerated() {
            let y = laneTop + baseLaneH + 3 + CGFloat(k) * (takeLaneH + 3)
            let x0 = max(0, xFor(lay.start).rounded()), x1 = min(f.w, xFor(lay.end).rounded())
            guard x1 > x0 else { continue }
            Pix.fill(c, x0, y, x1 - x0, takeLaneH, Ink.hex(0x281018))
            let clip = tl.clips[lay.clip]
            for xi in Int(x0)..<Int(x1) {
                let tt = tFor(CGFloat(xi))
                let color: UIColor = lay.clip == selectedClip ? Ink.cream : Ink.red
                waveColumn(c, x: CGFloat(xi), mid: y + takeLaneH / 2, half: takeLaneH / 2 - 2, peak: m.peak(clip.url, at: lay.src + (tt - lay.start)), color: color)
            }
        }
        if let s = m.solo, let lay = tl.layers.first(where: { $0.clip == s }) {
            // The whole original is playing: show its full file extent.
            let clip = tl.clips[s]
            let x0 = xFor(lay.start - clip.trimIn).rounded(), x1 = xFor(lay.start - clip.trimIn + clip.seconds).rounded()
            Pix.fill(c, x0, laneTop, max(1, x1 - x0), 1, Ink.purple)
        }
        if let i = selectedClip, let lay = tl.layers.first(where: { $0.clip == i }) {
            let isTake = tl.clips[i].isTake
            let k = takeLayers.firstIndex(of: lay) ?? 0
            let top = isTake ? laneTop + baseLaneH + 3 + CGFloat(k) * (takeLaneH + 3) : laneTop
            drawHandles(c, top: top, height: isTake ? takeLaneH : baseLaneH)
        }
    }

    private func handleXs() -> (CGFloat, CGFloat)? {
        guard let i = selectedClip, let lay = m.timeline.layers.first(where: { $0.clip == i }) else { return nil }
        return (xFor(lay.start).rounded(), xFor(lay.end).rounded())
    }

    private func drawHandles(_ c: CGContext, top: CGFloat, height: CGFloat) {
        guard let (a, b) = handleXs() else { return }
        for (x, left) in [(a, true), (b, false)] where x > -4 && x < f.w + 4 {
            Pix.fill(c, x - 1, top, 2, height, Ink.yellow)
            Pix.fill(c, left ? x - 1 : x - 4, top + height / 2 - 5, 5, 10, Ink.yellow)
            Pix.fill(c, left ? x + 1 : x - 2, top + height / 2 - 3, 1, 6, Ink.dark)
        }
    }

    private func clock10(_ s: Double) -> String {
        let v = max(0, s)
        let m = Int(v) / 60, sec = Int(v) % 60, tenth = Int((v - v.rounded(.down)) * 10)
        return String(format: "%02d:%02d.%d", m, sec, tenth)
    }

    // Keys: ⚑ MARK, ▶, ● over, ↺ reset trim.
    private func drawEditKeys(_ c: CGContext) {
        let tp = transport
        Pix.rrect(c, tp.minX, tp.minY, tp.width, tp.height, 6, Ink.ink)
        Pix.fill(c, tp.minX + 4, tp.minY + 2, tp.width - 8, 1, Ink.blue)
        let down: [Bool] = [m.mark != nil || heldKey == 0, m.playing || heldKey == 1, m.recording || heldKey == 2, heldKey == 3]
        for i in 0..<4 {
            let r = key(i)
            let sunk: CGFloat = down[i] ? 3 : 0
            let face = CGRect(x: r.minX, y: r.minY + sunk, width: r.width, height: r.height - 5)
            Pix.rrect(c, r.minX, face.maxY - 2, r.width, (down[i] ? 2 : 5) + 2, 3, Ink.dark)
            let rec = i == 2 && m.recording
            Pix.rrect(c, face.minX, face.minY, face.width, face.height, 3, rec ? Ink.red : (i == 0 && m.mark != nil ? Ink.yellow : (down[i] ? Ink.tan : Ink.cream)))
            if !down[i] { Pix.fill(c, face.minX + 3, face.minY + 1, face.width - 6, 1, UIColor.white.withAlphaComponent(0.6)) }
            let cx = face.midX.rounded(), cy = face.midY.rounded()
            let ink: UIColor = rec ? Ink.cream : Ink.dark
            switch i {
            case 0:
                Pix.fill(c, cx - 3, cy - 6, 1, 12, ink)
                Pix.poly(c, [CGPoint(x: cx - 2, y: cy - 6), CGPoint(x: cx + 5, y: cy - 3), CGPoint(x: cx - 2, y: cy)], ink)
            case 1:
                if m.playing { Pix.fill(c, cx - 4, cy - 5, 3, 10, ink); Pix.fill(c, cx + 2, cy - 5, 3, 10, ink) }
                else { Pix.tri(c, cx - 3, cy, 1.3, m.solo != nil || layersMode ? Ink.purple : ink) }
            case 2:
                Pix.circle(c, cx, cy, 5, rec ? Ink.cream : Ink.red)
            default:
                Pix.fill(c, cx - 5, cy - 1, 9, 2, ink); Pix.poly(c, [CGPoint(x: cx - 6, y: cy), CGPoint(x: cx - 2, y: cy - 4), CGPoint(x: cx - 2, y: cy + 4)], ink)
            }
        }
    }

    private func editDown(_ p: CGPoint) {
        if modePill.insetBy(dx: -3, dy: -4).contains(p) {
            layersMode.toggle()
            if !layersMode { m.setSolo(nil) }
            return
        }
        if zoomOut.insetBy(dx: -2, dy: -4).contains(p) { zoomIndex = max(0, zoomIndex - 1); return }
        if zoomIn.insetBy(dx: -2, dy: -4).contains(p) { zoomIndex = min(Pane.zooms.count - 1, zoomIndex + 1); return }
        if let i = (0..<4).first(where: { key($0).insetBy(dx: -1, dy: -4).contains(p) }) {
            heldKey = i
            gesture = .hold
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            if m.keyClicks { AudioServicesPlaySystemSound(1104) }
            switch i {
            case 0:
                if let mk = m.mark, abs(mk - m.position) < 0.3 { m.mark = nil } else { m.setSolo(nil); m.mark = m.position }
            case 1:
                if layersMode, let s = selectedClip { if m.solo != s { m.setSolo(s) }; m.togglePlay() }
                else { m.setSolo(nil); m.togglePlay() }
            case 2:
                if !m.recording && m.mark == nil { m.setSolo(nil); m.mark = m.position }
                m.toggleRecording()
            default:
                if let s = selectedClip { m.resetTrim(clip: s) }
            }
            return
        }
        guard p.y >= laneTop - 8, p.y <= lanesBottom + 4 else { return }
        gesture = .scrub
        editDrag = .pan
        if let (a, b) = handleXs() {
            if abs(p.x - a) <= 6 { editDrag = .trimIn } else if abs(p.x - b) <= 6 { editDrag = .trimOut }
        }
        if editDrag != .pan { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    private func editMove(_ p: CGPoint) {
        let dx = p.x - lastPoint.x
        switch editDrag {
        case .pan:
            if m.solo != nil { m.setSolo(nil) }
            m.seek(m.position - Double(dx / zoom))
        case .trimIn, .trimOut:
            guard let i = selectedClip, m.timeline.clips.indices.contains(i) else { return }
            let c = m.timeline.clips[i]
            let d = Double(dx / zoom)
            if editDrag == .trimIn { m.setTrim(clip: i, trimIn: c.trimIn + d, trimOut: c.outPoint, save: false) }
            else { m.setTrim(clip: i, trimIn: c.trimIn, trimOut: c.outPoint + d, save: false) }
        case .none: break
        }
    }

    private func editUp(_ p: CGPoint) {
        defer { editDrag = .none }
        switch editDrag {
        case .trimIn, .trimOut:
            if let i = selectedClip, m.timeline.clips.indices.contains(i) {
                let c = m.timeline.clips[i]
                m.setTrim(clip: i, trimIn: c.trimIn, trimOut: c.outPoint, save: true)
            }
        case .pan where !moved:
            // A tap selects whatever is under the finger.
            let tt = tFor(p.x)
            let tl = m.timeline
            if layersMode {
                if p.y < laneTop + baseLaneH {
                    selectedClip = tl.layers.first { !tl.clips[$0.clip].isTake && tt >= $0.start && tt < $0.end }?.clip
                } else {
                    let k = Int((p.y - laneTop - baseLaneH - 3) / (takeLaneH + 3))
                    let lanes = Array(takeLayers.prefix(maxTakeLanes))
                    selectedClip = lanes.indices.contains(k) && tt >= lanes[k].start && tt < lanes[k].end ? lanes[k].clip : nil
                }
                if let s = m.solo, s != selectedClip { m.setSolo(nil) }
            } else {
                selectedClip = tl.segmentIndex(at: tt).map { tl.segments[$0].clip }
            }
            UISelectionFeedbackGenerator().selectionChanged()
        default: break
        }
    }

    // MARK: input

    func down(_ p: CGPoint) {
        downPoint = p; lastPoint = p; moved = false; gesture = .none; windCarry = 0; lastDy = 0
        if p.y >= f.tabTop {
            let n = Screen.tabs.count
            switchTo(Screen.tabs[min(n - 1, max(0, Int(p.x / (f.w / CGFloat(n)))))])
            return
        }
        switch screen {
        case .deck: deckDown(p)
        case .shelf: shelfDown(p)
        case .clips:
            gesture = .scroll; fling = 0
            startRenameTimer(at: p)
        case .label: labelDown(p)
        case .edit: editDown(p)
        case .settings: settingsDown(p)
        }
    }

    func move(_ p: CGPoint) {
        guard let d = downPoint else { return }
        if hypot(p.x - d.x, p.y - d.y) > 3 { moved = true }
        switch gesture {
        case .wind:
            if moved { press.cancel(); stopPressTimer() }
            windBy(p.x - lastPoint.x, pixelsPerNotch: 4)
        case .scroll:
            if moved { renameTimer?.invalidate(); renameTimer = nil }
            let dy = p.y - lastPoint.y
            lastDy = dy
            scrollBy(-dy)
        case .paint:
            paint(from: lastPoint, to: p)
        case .scrub:
            if screen == .edit { editMove(p) } else { shuttle(to: p.x) }
        default: break
        }
        lastPoint = p
    }

    func up(_ p: CGPoint) {
        defer { downPoint = nil; gesture = .none }
        switch gesture {
        case .wind:
            stopPressTimer()
            if press.up(at: CACurrentMediaTime()) == .tap { m.togglePlay() }
        case .hold:
            if screen == .edit { heldKey = nil } else { keyUp() }
        case .scroll:
            renameTimer?.invalidate(); renameTimer = nil
            if renamedOnHold { renamedOnHold = false; return }
            if moved { fling = -lastDy }
            else if playBar.contains(p) { m.togglePlay() }
            else if p.y >= topV && p.y <= botV {
                let off = headY - posToY(m.position)
                if let r = rows().first(where: { p.y - off >= $0.y && p.y - off < $0.y + $0.h + 2 }) {
                    m.seek(min(m.timeline.total, m.timeline.start(of: r.index) + 0.01))
                }
            }
        case .paint:
            if let img = inkWorking { m.setInk(img, save: true) }
            inkWorking = nil
        case .scrub:
            if screen == .edit { editUp(p) } else { shuttleRelease() }
        case .none: break
        }
    }

    private var renameTimer: Timer?
    private var renamedOnHold = false

    /// Hold a clip to rename its place. The name sticks to that spot for later recordings.
    private func startRenameTimer(at p: CGPoint) {
        renameTimer?.invalidate()
        renamedOnHold = false
        renameTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self, !self.moved, p.y >= self.topV, p.y <= self.botV else { return }
            let off = self.headY - self.posToY(self.m.position)
            guard let r = self.rows().first(where: { p.y - off >= $0.y && p.y - off < $0.y + $0.h + 2 }) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.renamedOnHold = true
            self.m.beginClipRename(r.clip)
            self.onEditName?()
        }
    }

    private func switchTo(_ s: Screen) {
        if screen == .edit && s != .edit { m.setSolo(nil) }
        if screen == .label && s != .label && m.editing == .tape { m.renameCurrent(m.nameDraft) }
        screen = s
    }

    private func hit(_ p: CGPoint, _ c: CGPoint, _ r: CGFloat) -> Bool { hypot(p.x - c.x, p.y - c.y) < r }

    private func deckDown(_ p: CGPoint) {
        if !m.timeline.isEmpty && !m.recording && scrubRect.contains(p) {
            gesture = .scrub
            shuttleStartX = p.x
            shuttleOffset = 0
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        if cas.contains(p) {
            gesture = .wind
            if press.down(at: CACurrentMediaTime(), recording: m.recording) == .stopRecording { m.stopRecording(); press.cancel(); return }
            startPressTimer()
        } else if headerPill.insetBy(dx: -4, dy: -4).contains(p) && !m.recording {
            switchTo(.shelf)
        } else if let i = (0..<4).first(where: { key($0).insetBy(dx: -1, dy: -4).contains(p) }) {
            keyDown(i)
        }
    }

    /// Keys clunk down with a haptic and a click. ▶ and ● act on the press; ◀◀ and ▶▶ skip a
    /// clip on a tap and wind while held, faster the longer you hold.
    private func keyDown(_ i: Int) {
        heldKey = i
        gesture = .hold
        keyDownAt = CACurrentMediaTime()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
        if m.keyClicks { AudioServicesPlaySystemSound(1104) }
        switch i {
        case 1: m.togglePlay()
        case 2: m.toggleRecording()
        default:
            let dir: Double = i == 0 ? -1 : 1
            keyTimer?.invalidate()
            keyTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                let held = CACurrentMediaTime() - self.keyDownAt
                if held >= 0.25 { self.m.holdRate = dir * (held > 1.5 ? 8 : 4) }
            }
        }
    }

    private func keyUp() {
        guard let i = heldKey else { return }
        keyTimer?.invalidate(); keyTimer = nil
        if i == 0 || i == 3 {
            if CACurrentMediaTime() - keyDownAt < 0.25 { m.skip(i == 0 ? -1 : 1) }
            m.holdRate = nil
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        heldKey = nil
    }

    private func startPressTimer() {
        stopPressTimer()
        pressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.press.tick(at: CACurrentMediaTime()) == .holdStart {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                self.m.startRecording()
                self.stopPressTimer()
            }
        }
    }

    private func stopPressTimer() { pressTimer?.invalidate(); pressTimer = nil }

    private func shelfDown(_ p: CGPoint) {
        if headerPill.insetBy(dx: -2, dy: -4).contains(p) && !m.recording { m.newTape(); return }
        if bgPill.insetBy(dx: -4, dy: -4).contains(p) { switchTo(.settings); return }
        let h = f.cassetteH
        for slot in shelfLayout().reversed() where p.x >= f.left && p.x <= f.right && p.y >= slot.y && p.y <= slot.y + (slot.front ? h : slot.step) {
            if !m.recording { m.select(slot.index) }
            return
        }
    }

    private func labelDown(_ p: CGPoint) {
        let lr = labelRect
        if tool != .none && CGRect(x: lr.minX, y: lr.minY + 12, width: lr.width, height: lr.height - 12).contains(p) {
            gesture = .paint
            paint(from: p, to: p)
            return
        }
        for (i, k) in Pattern.allCases.enumerated() where swatch(i).insetBy(dx: -1, dy: -1).contains(p) { m.setLabel(pattern: k) }
        for i in 0..<6 where pairRect(i).insetBy(dx: -1, dy: -2).contains(p) { m.setLabel(pair: i) }
        for (i, item) in tools.enumerated() where toolRect(i).contains(p) {
            if let tl = item.0 { tool = tool == tl ? .none : tl } else { m.setInk(nil, save: true) }
        }
        if nameBox.contains(p) { m.beginTapeRename(); onEditName?() }
        if headerPill.insetBy(dx: -4, dy: -4).contains(p) { switchTo(.shelf) }
    }

    private func paint(from a: CGPoint, to b: CGPoint) {
        guard let tape = m.tape else { return }
        let lr = labelRect
        let size = lr.size
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let base = inkWorking ?? m.inks[tape.id]
        let erase = tool == .erase
        inkWorking = UIGraphicsImageRenderer(size: size, format: fmt).image { r in
            let c = r.cgContext
            c.setShouldAntialias(false)
            c.interpolationQuality = .none
            base?.draw(in: CGRect(origin: .zero, size: size))
            let n = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y))))
            for i in 0...n {
                let x = (a.x + (b.x - a.x) * CGFloat(i) / CGFloat(n) - lr.minX).rounded()
                let y = (a.y + (b.y - a.y) * CGFloat(i) / CGFloat(n) - lr.minY).rounded()
                if erase { c.clear(CGRect(x: x - 2, y: y - 2, width: 4, height: 4)) }
                else { c.setFillColor(Ink.navy.cgColor); c.fill(CGRect(x: x - 1, y: y - 1, width: 2, height: 2)) }
            }
        }
    }
}
