import UIKit

/// Patterns and the cassette itself, drawn at canvas scale.
enum Cassette {
    static func pattern(_ c: CGContext, _ kind: Pattern, _ pair: Int, _ r: CGRect) {
        let (a, b) = Ink.pairs[max(0, min(5, pair))]
        c.saveGState(); c.clip(to: r)
        Pix.fill(c, r.minX, r.minY, r.width, r.height, a)
        let x = r.minX, y = r.minY, w = r.width, h = r.height
        switch kind {
        case .bands:
            var k = -h
            while k < w + h {
                Pix.poly(c, [CGPoint(x: x + k, y: y + h), CGPoint(x: x + k + 5, y: y + h), CGPoint(x: x + k + 5 + h, y: y), CGPoint(x: x + k + h, y: y)], b)
                k += 10
            }
        case .spots:
            var j = 0; var yy = y + 2
            while yy < y + h {
                var xx = x + 2 + (j % 2 == 1 ? 3 : 0)
                while xx < x + w { Pix.fill(c, xx, yy, 3, 3, b); xx += 6 }
                yy += 6; j += 1
            }
        case .stripes:
            var xx = x
            while xx < x + w { Pix.fill(c, xx, y, 4, h, b); xx += 8 }
        case .checks:
            var j = 0
            while CGFloat(j * 6) < h {
                var i = 0
                while CGFloat(i * 6) < w { if (i + j) % 2 == 1 { Pix.fill(c, x + CGFloat(i * 6), y + CGFloat(j * 6), 6, 6, b) }; i += 1 }
                j += 1
            }
        case .waves:
            c.setStrokeColor(b.cgColor); c.setLineWidth(2)
            var yy = y + 3
            while yy < y + h + 4 {
                var xx = x - 4; var k = 0
                c.move(to: CGPoint(x: xx, y: yy))
                while xx < x + w + 6 { c.addLine(to: CGPoint(x: xx, y: yy + (k % 2 == 1 ? 3 : 0))); xx += 4; k += 1 }
                c.strokePath()
                yy += 7
            }
        case .photo:
            Pix.vgrad(c, r, [(0, Ink.hex(0xf8e070)), (0.45, Ink.orange), (0.8, Ink.red), (1, Ink.purple)])
            Pix.circle(c, x + w * 0.62, y + h * 0.55, h * 0.28, Ink.hex(0xfff8d0))
            Pix.fill(c, x, y + h - 3, w, 3, Ink.navy)
            cat(c, x + w * 0.3, y + h - 6, h / 34)
        }
        c.restoreGState()
    }

    /// Basil, in silhouette, on the sunset label.
    static func cat(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ s: CGFloat) {
        c.setFillColor(Ink.navy.cgColor)
        c.fillEllipse(in: CGRect(x: x - 7 * s, y: y - 5 * s, width: 14 * s, height: 10 * s))
        Pix.circle(c, x + 6 * s, y - 5 * s, 3.5 * s, Ink.navy)
        Pix.poly(c, [CGPoint(x: x + 3.5 * s, y: y - 7 * s), CGPoint(x: x + 4.5 * s, y: y - 11 * s), CGPoint(x: x + 6.5 * s, y: y - 8 * s)], Ink.navy)
        Pix.poly(c, [CGPoint(x: x + 6.5 * s, y: y - 8 * s), CGPoint(x: x + 8.5 * s, y: y - 11 * s), CGPoint(x: x + 9 * s, y: y - 6 * s)], Ink.navy)
        Pix.fill(c, x - 9 * s, y - 6 * s, 2 * s, 6 * s, Ink.navy)
    }

    /// The label rectangle for a cassette drawn at (x, y, w, h). The ink image fills it.
    static func labelRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x + 8, y: y + 6, width: w - 16, height: (h * 0.62).rounded())
    }

    static func draw(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     name: String, label: LabelSpec, ink: UIImage?, fraction p: Double, rot: Double, duration: String? = nil, t: Double = 0) {
        Pix.rrect(c, x - 1, y - 1, w + 2, h + 2, 6, Ink.dark)
        c.saveGState()
        c.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 5).cgPath); c.clip()
        Pix.vgrad(c, CGRect(x: x, y: y, width: w, height: h), [(0, Ink.cream), (1, Ink.hex(0xa88860))])
        c.restoreGState()
        let left: CGFloat = x + 3, right: CGFloat = x + w - 5, top: CGFloat = y + 3, bottom: CGFloat = y + h - 5
        let screws: [CGPoint] = [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)]
        for s in screws { Pix.fill(c, s.x, s.y, 2, 2, Ink.grey) }

        let lr = labelRect(x, y, w, h)
        Pix.fill(c, lr.minX - 1, lr.minY - 1, lr.width + 2, lr.height + 2, Ink.dark)
        pattern(c, label.pattern, label.pair, lr)
        if let ink, let cg = ink.cgImage {
            c.saveGState()
            c.interpolationQuality = .none
            c.translateBy(x: lr.minX, y: lr.maxY); c.scaleBy(x: 1, y: -1)
            c.draw(cg, in: CGRect(x: 0, y: 0, width: lr.width, height: lr.height))
            c.restoreGState()
        }
        Pix.fill(c, lr.minX, lr.minY, lr.width, 12, Ink.cream)
        Pix.marquee(c, name.uppercased(), lr.minX + 3, lr.minY + 2, maxW: lr.width - 14, Ink.dark, t: t)
        Pix.text("A", lr.maxX - 3, lr.minY + 2, Ink.red, font: Pix.bold, align: .right)
        if let duration {
            let tw = ceil(Pix.width(duration)) + 5
            Pix.fill(c, lr.maxX - tw - 2, lr.minY + 14, tw, 11, Ink.cream)
            Pix.text(duration, lr.maxX - 4, lr.minY + 16, Ink.dark, align: .right)
        }

        let wx: CGFloat = x + (w * 0.2).rounded()
        let wy: CGFloat = y + (h * 0.43).rounded()
        let ww: CGFloat = (w * 0.6).rounded()
        let wh: CGFloat = (h * 0.33).rounded()
        Pix.rrect(c, wx - 1, wy - 1, ww + 2, wh + 2, wh / 2, Ink.dark)
        Pix.rrect(c, wx, wy, ww, wh, wh / 2, Ink.windowDark)
        let cy: CGFloat = wy + wh / 2
        let c1: CGFloat = wx + wh / 2 + 1
        let c2: CGFloat = wx + ww - wh / 2 - 1
        let rm: CGFloat = wh / 2 - 1
        let f = CGFloat(min(max(p, 0), 1))
        Pix.circle(c, c1, cy, 4 + (1 - f) * (rm - 4), Ink.brown)
        Pix.circle(c, c2, cy, 4 + f * (rm - 4), Ink.brown)
        for cx in [c1, c2] {
            Pix.circle(c, cx, cy, 4, Ink.cream)
            c.setStrokeColor(Ink.dark.cgColor); c.setLineWidth(1.2)
            for k in 0..<3 {
                let a = CGFloat(rot) + CGFloat(k) * 2.094
                c.move(to: CGPoint(x: cx, y: cy)); c.addLine(to: CGPoint(x: cx + cos(a) * 4, y: cy + sin(a) * 4)); c.strokePath()
            }
        }
        let by: CGFloat = y + h, bt: CGFloat = y + h - 9
        let foot: [CGPoint] = [CGPoint(x: x + 16, y: by), CGPoint(x: x + 23, y: bt), CGPoint(x: x + w - 23, y: bt), CGPoint(x: x + w - 16, y: by)]
        Pix.poly(c, foot, Ink.dark.withAlphaComponent(0.45))
    }
}
