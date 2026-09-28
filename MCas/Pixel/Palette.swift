import UIKit

/// Sixteen colors, each channel a multiple of 8 so they sit on a 15-bit grid, and a 4×4
/// ordered Bayer dither to get between them. Every frame of the app goes through this.
enum Palette {
    static let rgb: [(UInt8, UInt8, UInt8)] = [
        (8, 8, 16), (24, 24, 48), (40, 48, 88), (64, 80, 136),
        (48, 160, 136), (136, 216, 176), (248, 240, 200), (224, 200, 144),
        (160, 104, 48), (88, 48, 32), (224, 64, 64), (248, 152, 56),
        (248, 216, 72), (240, 128, 160), (128, 88, 176), (168, 168, 184)
    ]

    /// Nearest palette entry for every 15-bit color.
    static let lut: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 32768)
        for r in 0..<32 { for g in 0..<32 { for b in 0..<32 {
            let R: Int = r * 8 + 4
            let G: Int = g * 8 + 4
            let B: Int = b * 8 + 4
            var best = 0
            var bd = Int.max
            for i in 0..<rgb.count {
                let dr: Int = R - Int(rgb[i].0)
                let dg: Int = G - Int(rgb[i].1)
                let db: Int = B - Int(rgb[i].2)
                let d: Int = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                if d < bd { bd = d; best = i }
            }
            t[(r << 10) | (g << 5) | b] = UInt8(best)
        } } }
        return t
    }()

    static let bayer: [Int] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { (v: Int) -> Int in
        let f: Double = (Double(v) + 0.5) / 16.0 - 0.5
        return Int(f * 44.0)
    }

    static func quantize(_ p: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        lut.withUnsafeBufferPointer { lut in
            for y in 0..<height {
                let row = (y & 3) << 2
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let t: Int = bayer[row | (x & 3)]
                    let r: Int = min(255, max(0, Int(p[i]) + t)) >> 3
                    let g: Int = min(255, max(0, Int(p[i + 1]) + t)) >> 3
                    let b: Int = min(255, max(0, Int(p[i + 2]) + t)) >> 3
                    let key: Int = (r << 10) | (g << 5) | b
                    let c = rgb[Int(lut[key])]
                    p[i] = c.0; p[i + 1] = c.1; p[i + 2] = c.2; p[i + 3] = 255
                }
            }
        }
    }
}

enum Ink {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    static let ink = hex(0x080810), navy = hex(0x181830), blue = hex(0x283058), blue2 = hex(0x405088)
    static let teal = hex(0x30a088), mint = hex(0x88d8b0), cream = hex(0xf8f0c8), tan = hex(0xe0c890)
    static let brown = hex(0xa06830), dark = hex(0x583020), red = hex(0xe04040), orange = hex(0xf89838)
    static let yellow = hex(0xf8d848), pink = hex(0xf080a0), purple = hex(0x8058b0), grey = hex(0xa8a8b8)
    static let windowDark = hex(0x281810)

    static let pairs: [(UIColor, UIColor)] = [(yellow, orange), (mint, teal), (blue2, purple), (pink, red), (tan, brown), (cream, blue)]
    static let clipColors: [UIColor] = [orange, yellow, mint, blue2, pink, tan]
}

/// A 136×296 canvas with UIKit's top-left origin, quantized on every frame.
final class PixelCanvas {
    static let W = 136, H = 296
    let ctx: CGContext
    private let data: UnsafeMutablePointer<UInt8>

    init() {
        data = .allocate(capacity: Self.W * Self.H * 4)
        data.initialize(repeating: 0, count: Self.W * Self.H * 4)
        ctx = CGContext(data: data, width: Self.W, height: Self.H, bitsPerComponent: 8, bytesPerRow: Self.W * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(Self.H))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.interpolationQuality = .none
    }

    deinit { data.deallocate() }

    func frame(_ draw: (CGContext) -> Void) -> CGImage? {
        UIGraphicsPushContext(ctx)
        ctx.saveGState()
        draw(ctx)
        ctx.restoreGState()
        UIGraphicsPopContext()
        Palette.quantize(data, width: Self.W, height: Self.H)
        return ctx.makeImage()
    }
}
