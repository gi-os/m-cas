import UIKit

/// Drawing primitives in canvas pixels.
enum Pix {
    static let regular = UIFont(name: "Silkscreen-Regular", size: 8) ?? .monospacedSystemFont(ofSize: 7, weight: .regular)
    static let bold = UIFont(name: "Silkscreen-Bold", size: 8) ?? .monospacedSystemFont(ofSize: 7, weight: .bold)
    static let big = UIFont(name: "Silkscreen-Bold", size: 16) ?? .monospacedSystemFont(ofSize: 14, weight: .bold)

    enum Align { case left, center, right }

    static func fill(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ col: UIColor) {
        c.setFillColor(col.cgColor); c.fill(CGRect(x: x, y: y, width: w, height: h))
    }

    static func rrect(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ col: UIColor) {
        c.setFillColor(col.cgColor)
        c.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: min(r, min(w, h) / 2)).cgPath)
        c.fillPath()
    }

    static func circle(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: UIColor) {
        guard r > 0 else { return }
        c.setFillColor(col.cgColor); c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    static func poly(_ c: CGContext, _ pts: [CGPoint], _ col: UIColor) {
        guard let f = pts.first else { return }
        c.setFillColor(col.cgColor); c.move(to: f); pts.dropFirst().forEach { c.addLine(to: $0) }; c.closePath(); c.fillPath()
    }

    static func tri(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ dir: CGFloat, _ col: UIColor) {
        poly(c, [CGPoint(x: x, y: y - 5), CGPoint(x: x + 6 * dir, y: y), CGPoint(x: x, y: y + 5)], col)
    }

    @discardableResult
    static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ col: UIColor, font: UIFont = regular, align: Align = .left) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: col]
        let str = s as NSString
        let w = str.size(withAttributes: attrs).width
        let ox: CGFloat = align == .left ? x : align == .center ? x - w / 2 : x - w
        str.draw(at: CGPoint(x: ox.rounded(), y: y - 1), withAttributes: attrs)
        return w
    }

    static func width(_ s: String, font: UIFont = regular) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    static func vgrad(_ c: CGContext, _ rect: CGRect, _ stops: [(CGFloat, UIColor)]) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map { $0.1.cgColor } as CFArray, locations: stops.map { $0.0 }) else { return }
        c.saveGState(); c.clip(to: rect)
        c.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        c.restoreGState()
    }

    static func glow(_ c: CGContext, _ center: CGPoint, _ radius: CGFloat, _ col: UIColor) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [col.cgColor, col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { return }
        c.drawRadialGradient(g, startCenter: center, startRadius: 2, endCenter: center, endRadius: radius, options: [])
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    static func short(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Stars in the sky behind every screen; fixed positions, twinkling.
enum Sky {
    static let stars: [(CGFloat, CGFloat, Double)] = {
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        return (0..<34).map { _ in (CGFloat(Int(rnd() * 136)), CGFloat(Int(rnd() * 296 * 0.62)), rnd()) }
    }()

    static func draw(_ c: CGContext, _ t: Double, _ top: UIColor, _ mid: UIColor, _ bot: UIColor) {
        Pix.vgrad(c, CGRect(x: 0, y: 0, width: 136, height: 296), [(0, top), (0.5, mid), (1, bot)])
        for (x, y, p) in stars where sin(t / 0.6 + p * 20) > -0.2 {
            Pix.fill(c, x, y, 1, 1, p > 0.8 ? Ink.yellow : Ink.cream)
        }
    }
}
