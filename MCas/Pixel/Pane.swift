import UIKit
import SwiftUI

enum Screen: Int, CaseIterable {
    case deck, shelf, clips, label
    var title: String { ["DECK", "SHELF", "CLIPS", "LABEL"][rawValue] }
}

enum Tool: String { case draw, erase, none }

/// One pixel screen: what it shows, and what a finger on it does. The layouts and hit areas
/// match the mockup, so the mockup is the spec.
final class Pane: ObservableObject {
    @Published var screen: Screen
    var onEditName: (() -> Void)?

    private var canvas = PixelCanvas()
    private(set) var offset = CGPoint.zero
    private var full = CGRect(x: 0, y: 0, width: 136, height: 296)
    private static let clockFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm"; return f }()
    private let m = Machine.shared
    private var rot: Double = 0
    private var lastFrame = CACurrentMediaTime()
    private let haptic = UISelectionFeedbackGenerator()

    // gesture state
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

    private enum Kind { case none, wind, scroll, paint, hold }

    init(screen: Screen) { self.screen = screen }

    // MARK: frame

    /// Size the canvas to the screen (in whole device pixels) and place the layout inside the
    /// safe area, centered.
    private func configure(width: Int, height: Int, safeTop: Int, safeBottom: Int) {
        if canvas.width != width || canvas.height != height { canvas = PixelCanvas(width: width, height: height) }
        let ox = max(0, (width - PixelCanvas.W) / 2)
        let avail = height - safeTop - safeBottom
        let oy = avail >= PixelCanvas.H ? safeTop + (avail - PixelCanvas.H) / 2 : max(0, (height - PixelCanvas.H) / 2)
        offset = CGPoint(x: ox, y: oy)
    }

    /// A point on the canvas, in canvas pixels, as a point in the 136×296 layout.
    func layoutPoint(_ canvasPoint: CGPoint) -> CGPoint { CGPoint(x: canvasPoint.x - offset.x, y: canvasPoint.y - offset.y) }

    func render(at t: Double, width: Int, height: Int, safeTop: Int, safeBottom: Int) -> CGImage? {
        configure(width: width, height: height, safeTop: safeTop, safeBottom: safeBottom)
        let now = CACurrentMediaTime()
        let dt = min(0.12, now - lastFrame)
        lastFrame = now
        if !UIAccessibility.isReduceMotionEnabled { rot += m.rate * dt * 5 }
        if fling != 0 {
            scrollBy(fling)
            fling *= 0.85
            if abs(fling) < 0.3 { fling = 0 }
        }
        return canvas.frame(offset: offset) { c, full in
            self.full = full
            switch screen {
            case .deck: drawDeck(c, t)
            case .shelf: drawShelf(c, t)
            case .clips: drawClips(c, t)
            case .label: drawLabel(c, t)
            }
        }
    }

    private func chrome(_ c: CGContext, _ t: Double) {
        Pix.text(Self.clockFormat.string(from: Date()), 9, 5, Ink.cream)
        let level = UIDevice.current.batteryLevel
        Pix.fill(c, 111, 6, 14, 7, Ink.cream); Pix.fill(c, 125, 8, 1, 3, Ink.cream)
        Pix.fill(c, 112, 7, 12, 5, Ink.ink)
        let cells = level < 0 ? 12 : max(1, Int((Float(12) * level).rounded()))
        Pix.fill(c, 112, 7, CGFloat(cells), 5, level >= 0 && level < 0.2 ? Ink.red : Ink.teal)
        if m.recording && screen != .deck {
            Pix.rrect(c, 36, 3, 64, 11, 6, Ink.ink)
            if Int(t / 0.4) % 2 == 1 { Pix.circle(c, 43, 8.5, 2, Ink.red) }
            Pix.text("REC", 48, 5, Ink.red)
            Pix.text(mmss(m.recSeconds), 96, 5, Ink.red, align: .right)
        }
    }

    private func tabs(_ c: CGContext) {
        Pix.fill(c, full.minX, 266, full.width, full.maxY - 266, Ink.hex(0x0c0c18))
        Pix.fill(c, full.minX, 266, full.width, 1, Ink.blue2)
        for s in Screen.allCases {
            let cx = CGFloat(17 + s.rawValue * 34), on = s == screen
            Pix.text(s.title, cx, 272, on ? Ink.yellow : Ink.grey, font: on ? Pix.bold : Pix.regular, align: .center)
            if on { Pix.fill(c, cx - 9, 282, 18, 1, Ink.yellow) }
        }
    }

    private func mmss(_ s: Double) -> String { let v = Int(s); return String(format: "%02d:%02d", v / 60, v % 60) }

    private func pill(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ label: String, _ bg: UIColor, _ fg: UIColor) {
        Pix.rrect(c, x, y, w, 13, 6, bg)
        Pix.text(label, x + w / 2, y + 3, fg, align: .center)
    }

    // MARK: deck

    private let cas = CGRect(x: 8, y: 50, width: 120, height: 77)
    private let bRew = CGPoint(x: 31, y: 240), bPlay = CGPoint(x: 52, y: 240), bRec = CGPoint(x: 84, y: 240), bFF = CGPoint(x: 107, y: 240)

    private func drawDeck(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.hex(0x283870), Ink.hex(0x141428), Ink.hex(0x1c2c40), in: full)
        Pix.glow(c, CGPoint(x: 68, y: 90), 78, Ink.teal.withAlphaComponent(0.6))
        chrome(c, t)
        guard let tape = m.tape else { return }
        Pix.text("ON THE MACHINE", 8, 24, Ink.mint)
        Pix.marquee(c, tape.name.uppercased(), 8, 34, maxW: 82, Ink.cream, font: Pix.bold, t: t)
        if m.recording {
            if Int(t / 0.4) % 2 == 1 { Pix.circle(c, 104, 30, 3, Ink.red) }
            Pix.text("REC", 128, 26, Ink.red, font: Pix.bold, align: .right)
        } else {
            pill(c, 94, 24, 34, "SHELF", Ink.blue2, Ink.cream)
        }
        let tl = m.timeline
        Cassette.draw(c, cas.minX, cas.minY, cas.width, cas.height, name: tape.name, label: tape.label, ink: m.inks[tape.id], fraction: tl.fraction(m.position), rot: rot, t: t)

        if m.recording {
            Pix.text("RECORDING", 8, 138, Ink.red, font: Pix.bold)
            Pix.text(mmss(m.recSeconds) + "  ONTO THE END", 8, 149, Ink.grey)
        } else if let i = tl.clipIndex(at: m.position) {
            let clip = tl.clips[i]
            Pix.marquee(c, clip.name.uppercased(), 8, 138, maxW: 120, Ink.cream, font: Pix.bold, t: t)
            Pix.marquee(c, Naming.short(clip.date), 8, 149, maxW: 120, Ink.grey, t: t)
        } else {
            Pix.text("EMPTY TAPE", 8, 138, Ink.cream, font: Pix.bold)
            Pix.text("HOLD THE TAPE TO RECORD", 8, 149, Ink.grey)
        }
        // the whole tape, clip by clip
        if !tl.isEmpty {
            var x: CGFloat = 8
            for (i, clip) in tl.clips.enumerated() {
                let w = max(2, (120 * CGFloat(clip.seconds / tl.total)).rounded() - 1)
                Pix.fill(c, x, 164, min(w, 128 - x), 9, Ink.clipColors[i % 6])
                x += w + 1
                if x >= 128 { break }
            }
            let hx = 8 + (CGFloat(tl.fraction(m.position)) * 119).rounded()
            Pix.fill(c, hx, 161, 1, 15, Ink.cream); Pix.fill(c, hx - 1, 160, 3, 2, Ink.cream)
        } else {
            Pix.fill(c, 8, 164, 120, 9, Ink.blue)
        }
        Pix.text(Pix.clock(m.position), 8, 181, Ink.cream)
        let r = m.rate
        Pix.text((r < 0 ? "-" : "") + String(format: "%.1fX", abs(r)), 68, 181, abs(r) > 1.1 ? Ink.yellow : Ink.mint, align: .center)
        Pix.text(Pix.clock(tl.total), 128, 181, Ink.grey, align: .right)
        for i in 0..<26 {
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
            Pix.fill(c, CGFloat(16 + i * 4), 211 - h, 3, h, i > 21 ? Ink.red : i > 17 ? Ink.yellow : Ink.teal)
        }
        Pix.rrect(c, 8, 222, 120, 36, 18, Ink.blue)
        Pix.fill(c, 22, 223, 92, 1, Ink.blue2)
        Pix.tri(c, 31, 240, -1, Ink.cream); Pix.tri(c, 37, 240, -1, Ink.cream)
        Pix.tri(c, 101, 240, 1, Ink.cream); Pix.tri(c, 107, 240, 1, Ink.cream)
        if m.playing { Pix.fill(c, 48, 235, 3, 10, Ink.cream); Pix.fill(c, 54, 235, 3, 10, Ink.cream) }
        else { Pix.tri(c, 49, 240, 1.4, Ink.cream) }
        Pix.circle(c, 84, 240, 12, Ink.cream)
        if m.recording { Pix.fill(c, 79, 235, 10, 10, Ink.red) } else { Pix.circle(c, 84, 240, 7, Ink.red) }
        tabs(c)
    }

    // MARK: shelf

    private struct ShelfSlot { let index: Int; let y: CGFloat; let front: Bool; let step: CGFloat }

    private func shelfLayout() -> [ShelfSlot] {
        var order = m.tapes.indices.filter { $0 != m.current }
        if m.tapes.indices.contains(m.current) { order.append(m.current) }
        let n = order.count
        let step: CGFloat = n > 1 ? min(40, (256 - 77 - 56) / CGFloat(n - 1)) : 0
        return order.enumerated().map { k, i in ShelfSlot(index: i, y: (56 + CGFloat(k) * step).rounded(), front: k == n - 1, step: step) }
    }

    private func drawShelf(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.navy, Ink.hex(0x202850), Ink.blue, in: full)
        chrome(c, t)
        Pix.text("SHELF", 8, 20, Ink.cream, font: Pix.big)
        if !m.recording { pill(c, 94, 22, 34, "+ NEW", Ink.teal, Ink.cream) }
        Pix.text("TAP A TAPE TO LOAD IT", 8, 40, Ink.grey)
        for slot in shelfLayout() {
            let tape = m.tapes[slot.index]
            Pix.rrect(c, 9, slot.y + 3, 121, 78, 6, Ink.ink.withAlphaComponent(0.7))
            let frac = slot.front ? m.timeline.fraction(m.position) : 0.5
            Cassette.draw(c, 8, slot.y, 120, 77, name: tape.name, label: tape.label, ink: m.inks[tape.id], fraction: frac,
                          rot: slot.front ? rot : 0, duration: Pix.short(m.totalSeconds(tape)), t: t + Double(slot.index))
            if slot.front && Int(t / 0.45) % 2 == 1 {
                Pix.poly(c, [CGPoint(x: 1, y: slot.y + 34), CGPoint(x: 5, y: slot.y + 38), CGPoint(x: 1, y: slot.y + 42)], Ink.yellow)
            }
        }
        tabs(c)
    }

    // MARK: clips — the tape runs past the head

    private let headY: CGFloat = 150, topV: CGFloat = 44, botV: CGFloat = 240

    private struct Row { let index: Int; let y: CGFloat; let h: CGFloat; let seconds: Double }

    private func rows() -> [Row] {
        var y: CGFloat = 0
        return m.timeline.clips.enumerated().map { i, c in
            let h = max(30, (CGFloat(c.seconds / 60) * 2.4).rounded())
            defer { y += h + 2 }
            return Row(index: i, y: y, h: h, seconds: c.seconds)
        }
    }

    private func posToY(_ pos: Double) -> CGFloat {
        let tl = m.timeline, rs = rows()
        guard let loc = tl.locate(pos), rs.indices.contains(loc.index) else { return 0 }
        let r = rs[loc.index]
        return r.y + CGFloat(r.seconds > 0 ? loc.offset / r.seconds : 0) * r.h
    }

    private func yToPos(_ y: CGFloat) -> Double {
        let tl = m.timeline, rs = rows()
        guard let last = rs.last else { return 0 }
        for r in rs where y <= r.y + r.h + 1 || r.index == last.index {
            let f = Double(min(1, max(0, (y - r.y) / r.h)))
            return min(tl.total, tl.start(of: r.index) + f * r.seconds)
        }
        return tl.total
    }

    private func scrollBy(_ dy: CGFloat) { m.seek(yToPos(posToY(m.position) + dy)) }

    private func drawClips(_ c: CGContext, _ t: Double) {
        let bg = Ink.hex(0x141428)
        Sky.draw(c, t, bg, Ink.navy, bg, in: full)
        chrome(c, t)
        guard let tape = m.tape else { return }
        let rs = rows(), off = headY - posToY(m.position)
        c.saveGState(); c.clip(to: CGRect(x: full.minX, y: topV, width: full.width, height: botV - topV))
        for r in rs {
            let y = (off + r.y).rounded()
            if y > botV || y + r.h < topV { continue }
            let clip = m.timeline.clips[r.index]
            let under = headY >= y && headY < y + r.h + 2
            Pix.fill(c, 8, y, 12, r.h, Ink.clipColors[r.index % 6])
            var yy = y + 3
            while yy < y + r.h - 2 { Pix.fill(c, 13, yy, 2, 2, Ink.dark); yy += 6 }
            Pix.rrect(c, 24, y, 104, r.h, 4, under ? Ink.cream : Ink.blue)
            let tc = under ? Ink.dark : Ink.cream, mc = under ? Ink.brown : Ink.grey
            Pix.marquee(c, clip.name.uppercased(), 28, y + 4, maxW: 96, tc, font: Pix.bold, t: t + Double(r.index))
            let dur = Pix.short(clip.seconds)
            let dw = Pix.text(dur, 124, y + 14, mc, align: .right)
            Pix.marquee(c, Naming.short(clip.date), 28, y + 14, maxW: 96 - ceil(dw) - 4, mc, t: t)
            if r.h >= 46 {
                for j in 0..<24 {
                    let seedV: Double = Double(j * 13 + r.index * 7)
                    let bh: CGFloat = 1 + CGFloat(Int(abs(sin(seedV)) * 5))
                    Pix.fill(c, CGFloat(28 + j * 4), y + r.h - 3 - bh, 3, bh, under ? Ink.brown : Ink.blue2)
                }
            }
        }
        c.restoreGState()
        if rs.isEmpty { Pix.text("NOTHING ON THIS TAPE YET", 68, 140, Ink.grey, align: .center) }
        Pix.vgrad(c, CGRect(x: full.minX, y: topV, width: full.width, height: 14), [(0, bg), (1, bg.withAlphaComponent(0))])
        Pix.vgrad(c, CGRect(x: full.minX, y: botV - 14, width: full.width, height: 14), [(0, bg.withAlphaComponent(0)), (1, bg)])
        Pix.fill(c, 4, headY, 128, 1, Ink.red)
        Pix.poly(c, [CGPoint(x: 0, y: headY - 4), CGPoint(x: 5, y: headY), CGPoint(x: 0, y: headY + 4)], Ink.cream)
        Pix.poly(c, [CGPoint(x: 136, y: headY - 4), CGPoint(x: 131, y: headY), CGPoint(x: 136, y: headY + 4)], Ink.cream)
        let pw = Pix.width(Pix.clock(m.position))
        Pix.marquee(c, tape.name.uppercased(), 8, 20, maxW: 120 - ceil(pw) - 4, Ink.cream, font: Pix.bold, t: t)
        Pix.text(Pix.clock(m.position), 128, 20, Ink.yellow, align: .right)
        Pix.text("\(rs.count) CLIPS", 8, 31, Ink.grey)
        Pix.text("DRAG TO WIND", 128, 31, Ink.blue2, align: .right)
        Pix.rrect(c, 8, 245, 120, 16, 8, m.playing ? Ink.blue2 : Ink.teal)
        if m.playing { Pix.fill(c, 18, 249, 2, 8, Ink.cream); Pix.fill(c, 22, 249, 2, 8, Ink.cream) }
        else { Pix.poly(c, [CGPoint(x: 18, y: 249), CGPoint(x: 24, y: 253), CGPoint(x: 18, y: 257)], Ink.cream) }
        Pix.text(m.playing ? "PLAYING" : "PLAY FROM HERE", 72, 249, Ink.cream, align: .center)
        tabs(c)
    }

    // MARK: label editor

    private let editCas = CGRect(x: 8, y: 44, width: 120, height: 77)
    private var labelRect: CGRect { Cassette.labelRect(editCas.minX, editCas.minY, editCas.width, editCas.height) }
    private let tools: [(Tool?, String, CGFloat, CGFloat)] = [(.draw, "DRAW", 8, 38), (.erase, "ERASE", 50, 38), (nil, "CLEAR", 92, 36)]

    private func drawLabel(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.hex(0x202850), Ink.navy, Ink.hex(0x141428), in: full)
        chrome(c, t)
        guard let tape = m.tape else { return }
        Pix.text("LABEL", 8, 20, Ink.cream, font: Pix.big)
        pill(c, 94, 22, 34, "DONE", Ink.blue2, Ink.cream)
        let name = m.nameDraft.isEmpty ? tape.name : m.nameDraft
        Cassette.draw(c, editCas.minX, editCas.minY, editCas.width, editCas.height, name: name, label: tape.label,
                      ink: inkWorking ?? m.inks[tape.id], fraction: m.timeline.fraction(m.position), rot: rot, t: t)
        Pix.text("NAME", 8, 128, Ink.grey)
        Pix.rrect(c, 8, 137, 120, 15, 3, Ink.cream)
        let w = Pix.tail(c, name.uppercased(), 12, 141, maxW: 110, Ink.dark, font: Pix.bold)
        if Int(t / 0.5) % 2 == 1 { Pix.fill(c, min(125, 13 + ceil(w)), 140, 1, 9, Ink.dark) }
        Pix.text("PATTERN", 8, 158, Ink.grey)
        for (i, k) in Pattern.allCases.enumerated() {
            let x = CGFloat(8 + i * 20)
            Pix.fill(c, x - 1, 166, 20, 20, k == tape.label.pattern ? Ink.yellow : Ink.dark)
            Cassette.pattern(c, k, tape.label.pair, CGRect(x: x, y: 167, width: 18, height: 18))
        }
        Pix.text("COLORS", 8, 191, Ink.grey)
        for (i, p) in Ink.pairs.enumerated() {
            let x = CGFloat(8 + i * 20)
            Pix.fill(c, x - 1, 199, 20, 14, i == tape.label.pair ? Ink.yellow : Ink.dark)
            Pix.fill(c, x, 200, 9, 12, p.0); Pix.fill(c, x + 9, 200, 9, 12, p.1)
        }
        for (tl, n, x, w) in tools {
            let on = tl != nil && tl == tool
            Pix.rrect(c, x, 220, w, 15, 4, on ? Ink.yellow : Ink.blue)
            Pix.text(n, x + w / 2, 224, on ? Ink.dark : Ink.cream, align: .center)
        }
        let hint = tool == .draw ? "DRAW ON THE LABEL" : tool == .erase ? "RUB OUT A LINE" : "TAP THE NAME TO RENAME"
        Pix.text(hint, 68, 246, Ink.blue2, align: .center)
        tabs(c)
    }

    // MARK: input

    func down(_ p: CGPoint) {
        downPoint = p; lastPoint = p; moved = false; gesture = .none; windCarry = 0; lastDy = 0
        if p.y >= 266 {
            if let s = Screen(rawValue: min(3, Int(p.x / 34))) { switchTo(s) }
            return
        }
        switch screen {
        case .deck: deckDown(p)
        case .shelf: shelfDown(p)
        case .clips: gesture = .scroll; fling = 0
        case .label: labelDown(p)
        }
    }

    func move(_ p: CGPoint) {
        guard let d = downPoint else { return }
        if hypot(p.x - d.x, p.y - d.y) > 3 { moved = true }
        switch gesture {
        case .wind:
            if moved { press.cancel(); stopPressTimer() }
            windCarry += p.x - lastPoint.x
            while abs(windCarry) >= 4 {
                let dir = windCarry > 0 ? 1 : -1
                m.notch(dir)
                haptic.selectionChanged()
                windCarry -= CGFloat(dir) * 4
            }
        case .scroll:
            let dy = p.y - lastPoint.y
            lastDy = dy
            scrollBy(-dy)
        case .paint:
            paint(from: lastPoint, to: p)
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
            m.holdRate = nil
        case .scroll:
            if moved { fling = -lastDy }
            else if CGRect(x: 8, y: 245, width: 120, height: 16).contains(p) { m.togglePlay() }
            else if p.y >= topV && p.y <= botV {
                let off = headY - posToY(m.position)
                if let r = rows().first(where: { p.y - off >= $0.y && p.y - off < $0.y + $0.h + 2 }) {
                    m.seek(min(m.timeline.total, m.timeline.start(of: r.index) + 0.01))
                }
            }
        case .paint:
            if let img = inkWorking { m.setInk(img, save: true) }
            inkWorking = nil
        case .none: break
        }
    }

    private func switchTo(_ s: Screen) {
        if screen == .label && s != .label { m.renameCurrent(m.nameDraft) }
        screen = s
    }

    private func hit(_ p: CGPoint, _ c: CGPoint, _ r: CGFloat) -> Bool { hypot(p.x - c.x, p.y - c.y) < r }

    private func deckDown(_ p: CGPoint) {
        if cas.contains(p) {
            gesture = .wind
            if press.down(at: CACurrentMediaTime(), recording: m.recording) == .stopRecording { m.stopRecording(); press.cancel(); return }
            startPressTimer()
        } else if CGRect(x: 94, y: 24, width: 34, height: 13).contains(p) && !m.recording {
            switchTo(.shelf)
        } else if hit(p, bPlay, 10) { m.togglePlay() }
        else if hit(p, bRec, 14) { m.toggleRecording() }
        else if hit(p, bRew, 10) { gesture = .hold; m.holdRate = -4 }
        else if hit(p, bFF, 10) { gesture = .hold; m.holdRate = 4 }
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
        if CGRect(x: 94, y: 22, width: 34, height: 13).contains(p) && !m.recording { m.newTape(); return }
        for slot in shelfLayout().reversed() where p.x >= 8 && p.x <= 128 && p.y >= slot.y && p.y <= slot.y + (slot.front ? 77 : slot.step) {
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
        for (i, k) in Pattern.allCases.enumerated() where CGRect(x: 8 + i * 20, y: 167, width: 18, height: 18).contains(p) { m.setLabel(pattern: k) }
        for i in 0..<6 where CGRect(x: 8 + i * 20, y: 200, width: 18, height: 12).contains(p) { m.setLabel(pair: i) }
        for (tl, _, x, w) in tools where CGRect(x: x, y: 220, width: w, height: 15).contains(p) {
            if let tl { tool = tool == tl ? .none : tl } else { m.setInk(nil, save: true) }
        }
        if CGRect(x: 8, y: 137, width: 120, height: 15).contains(p) { onEditName?() }
        if CGRect(x: 94, y: 22, width: 34, height: 13).contains(p) { switchTo(.shelf) }
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
