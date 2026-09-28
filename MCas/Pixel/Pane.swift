import UIKit
import SwiftUI

enum Screen: Int, CaseIterable {
    case deck, shelf, clips, label
    var title: String { ["DECK", "SHELF", "CLIPS", "LABEL"][rawValue] }
}

enum Tool: String { case draw, erase, none }

/// The frame of one screen, in canvas pixels. The canvas is sized to the display in whole
/// device pixels, so its width and height vary by phone; everything is placed against these
/// edges — header under the top inset, transport and tabs on the bottom inset, the cassette
/// as wide as the screen — rather than drawn into a fixed box.
struct Frame {
    let w: CGFloat, h: CGFloat
    let top: CGFloat      // first usable row, below the Dynamic Island
    let bottom: CGFloat   // last usable row, above the home indicator
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
    private var f = Frame(w: 136, h: 296, top: 0, bottom: 296)
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

    private enum Kind { case none, wind, scroll, paint, hold }

    init(screen: Screen) { self.screen = screen }

    /// Canvas pixels are the layout's own coordinates.
    func layoutPoint(_ canvasPoint: CGPoint) -> CGPoint { canvasPoint }

    func render(at t: Double, width: Int, height: Int, safeTop: Int, safeBottom: Int) -> CGImage? {
        if canvas.width != width || canvas.height != height { canvas = PixelCanvas(width: width, height: height) }
        f = Frame(w: CGFloat(width), h: CGFloat(height), top: CGFloat(safeTop), bottom: CGFloat(height - safeBottom))
        let now = CACurrentMediaTime()
        let dt = min(0.12, now - lastFrame)
        lastFrame = now
        if !UIAccessibility.isReduceMotionEnabled { rot += m.rate * dt * 5 }
        if fling != 0 {
            scrollBy(fling)
            fling *= 0.85
            if abs(fling) < 0.3 { fling = 0 }
        }
        return canvas.frame(offset: .zero) { c, _ in
            switch screen {
            case .deck: drawDeck(c, t)
            case .shelf: drawShelf(c, t)
            case .clips: drawClips(c, t)
            case .label: drawLabel(c, t)
            }
        }
    }

    // MARK: shared pieces

    private func chrome(_ c: CGContext, _ t: Double) {
        let y = f.top + 5
        Pix.text(Self.clockFormat.string(from: Date()), f.left + 1, y, Ink.cream)
        let level = UIDevice.current.batteryLevel
        let bx = f.right - 17
        Pix.fill(c, bx, y + 1, 14, 7, Ink.cream); Pix.fill(c, bx + 14, y + 3, 1, 3, Ink.cream)
        Pix.fill(c, bx + 1, y + 2, 12, 5, Ink.ink)
        let cells = level < 0 ? 12 : max(1, Int((Float(12) * level).rounded()))
        Pix.fill(c, bx + 1, y + 2, CGFloat(cells), 5, level >= 0 && level < 0.2 ? Ink.red : Ink.teal)
        if m.recording && screen != .deck {
            let cx = f.w / 2
            Pix.rrect(c, cx - 32, y - 2, 64, 11, 6, Ink.ink)
            if Int(t / 0.4) % 2 == 1 { Pix.circle(c, cx - 25, y + 3.5, 2, Ink.red) }
            Pix.text("REC", cx - 20, y, Ink.red)
            Pix.text(mmss(m.recSeconds), cx + 28, y, Ink.red, align: .right)
        }
    }

    private func tabs(_ c: CGContext) {
        let y = f.tabTop
        Pix.fill(c, 0, y, f.w, f.h - y, Ink.hex(0x0c0c18))
        Pix.fill(c, 0, y, f.w, 1, Ink.blue2)
        let slot = f.w / 4
        for s in Screen.allCases {
            let cx = (slot * CGFloat(s.rawValue) + slot / 2).rounded(), on = s == screen
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

    // MARK: deck

    private var cas: CGRect { CGRect(x: f.left, y: f.top + 50, width: f.width, height: f.cassetteH) }
    private var transport: CGRect { CGRect(x: f.left, y: f.tabTop - 44, width: f.width, height: 36) }
    private func button(_ i: Int) -> CGPoint {
        let fr: [CGFloat] = [0.19, 0.37, 0.63, 0.83]
        return CGPoint(x: (f.left + f.width * fr[i]).rounded(), y: transport.midY.rounded())
    }

    private func drawDeck(_ c: CGContext, _ t: Double) {
        Sky.draw(c, t, Ink.hex(0x283870), Ink.hex(0x141428), Ink.hex(0x1c2c40), in: f.full)
        Pix.glow(c, CGPoint(x: cas.midX, y: cas.midY), f.w * 0.6, Ink.teal.withAlphaComponent(0.6))
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
            Pix.text(mmss(m.recSeconds) + "  ONTO THE END", f.left, y + 11, Ink.grey)
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
            var x = f.left
            for (i, clip) in tl.clips.enumerated() {
                let w = max(2, (f.width * CGFloat(clip.seconds / tl.total)).rounded() - 1)
                Pix.fill(c, x, y, min(w, f.right - x), 9, Ink.clipColors[i % 6])
                x += w + 1
                if x >= f.right { break }
            }
            let hx = f.left + (CGFloat(tl.fraction(m.position)) * (f.width - 1)).rounded()
            Pix.fill(c, hx, y - 3, 1, 15, Ink.cream); Pix.fill(c, hx - 1, y - 4, 3, 2, Ink.cream)
        } else {
            Pix.fill(c, f.left, y, f.width, 9, Ink.blue)
        }
        y += 17
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

        let tp = transport
        Pix.rrect(c, tp.minX, tp.minY, tp.width, tp.height, 18, Ink.blue)
        Pix.fill(c, tp.minX + 14, tp.minY + 1, tp.width - 28, 1, Ink.blue2)
        let rew = button(0), play = button(1), rec = button(2), ff = button(3)
        Pix.tri(c, rew.x - 3, rew.y, -1, Ink.cream); Pix.tri(c, rew.x + 3, rew.y, -1, Ink.cream)
        Pix.tri(c, ff.x - 3, ff.y, 1, Ink.cream); Pix.tri(c, ff.x + 3, ff.y, 1, Ink.cream)
        if m.playing { Pix.fill(c, play.x - 4, play.y - 5, 3, 10, Ink.cream); Pix.fill(c, play.x + 2, play.y - 5, 3, 10, Ink.cream) }
        else { Pix.tri(c, play.x - 3, play.y, 1.4, Ink.cream) }
        Pix.circle(c, rec.x, rec.y, 12, Ink.cream)
        if m.recording { Pix.fill(c, rec.x - 5, rec.y - 5, 10, 10, Ink.red) } else { Pix.circle(c, rec.x, rec.y, 7, Ink.red) }
        tabs(c)
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
            let fr = Double(min(1, max(0, (y - r.y) / r.h)))
            return min(tl.total, tl.start(of: r.index) + fr * r.seconds)
        }
        return tl.total
    }

    private func scrollBy(_ dy: CGFloat) { m.seek(yToPos(posToY(m.position) + dy)) }

    private func drawClips(_ c: CGContext, _ t: Double) {
        let bg = Ink.hex(0x141428)
        Sky.draw(c, t, bg, Ink.navy, bg, in: f.full)
        chrome(c, t)
        guard let tape = m.tape else { return }
        let rs = rows(), off = headY - posToY(m.position)
        let cardX: CGFloat = 24, cardW = f.right - cardX
        c.saveGState(); c.clip(to: CGRect(x: 0, y: topV, width: f.w, height: botV - topV))
        for r in rs {
            let y = (off + r.y).rounded()
            if y > botV || y + r.h < topV { continue }
            let clip = m.timeline.clips[r.index]
            let under = headY >= y && headY < y + r.h + 2
            Pix.fill(c, f.left, y, 12, r.h, Ink.clipColors[r.index % 6])
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
        let name = m.nameDraft.isEmpty ? tape.name : m.nameDraft
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

    // MARK: input

    func down(_ p: CGPoint) {
        downPoint = p; lastPoint = p; moved = false; gesture = .none; windCarry = 0; lastDy = 0
        if p.y >= f.tabTop {
            if let s = Screen(rawValue: min(3, max(0, Int(p.x / (f.w / 4))))) { switchTo(s) }
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
        } else if headerPill.insetBy(dx: -4, dy: -4).contains(p) && !m.recording {
            switchTo(.shelf)
        } else if hit(p, button(1), 11) { m.togglePlay() }
        else if hit(p, button(2), 15) { m.toggleRecording() }
        else if hit(p, button(0), 11) { gesture = .hold; m.holdRate = -4 }
        else if hit(p, button(3), 11) { gesture = .hold; m.holdRate = 4 }
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
        if headerPill.insetBy(dx: -4, dy: -4).contains(p) && !m.recording { m.newTape(); return }
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
        if nameBox.contains(p) { onEditName?() }
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
