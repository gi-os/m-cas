import SwiftUI
import UIKit

/// A pixel screen that fills its space edge to edge. Each canvas pixel is a whole number of
/// device pixels, so nothing smears, and the canvas grows to cover the screen instead of
/// leaving borders.
struct PaneView: View {
    @ObservedObject var pane: Pane
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    @Environment(\.displayScale) private var scale
    @State private var touching = false

    var body: some View {
        GeometryReader { geo in
            let pxW = geo.size.width * scale
            let pxH = geo.size.height * scale
            let st = safeTop * scale, sb = safeBottom * scale
            // Whole device pixels per canvas pixel, chosen so the canvas is at least 136 wide and
            // has room for the layout between the insets.
            let k = max(1, min(floor(pxW / CGFloat(PixelCanvas.W)), floor(max(1, pxH - st - sb) / 300)))
            let cw = Int(ceil(pxW / k)), ch = Int(ceil(pxH / k))
            let wPt = CGFloat(cw) * k / scale, hPt = CGFloat(ch) * k / scale
            let toCanvas = { (p: CGPoint) in pane.layoutPoint(CGPoint(x: p.x * scale / k, y: p.y * scale / k)) }
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { tl in
                if let img = pane.render(at: tl.date.timeIntervalSinceReferenceDate, width: cw, height: ch,
                                         safeTop: Int(ceil(st / k)), safeBottom: Int(ceil(sb / k))) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: wPt, height: hPt)
                }
            }
            .frame(width: wPt, height: hPt)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        let p = toCanvas(v.location)
                        if !touching { touching = true; pane.down(p) } else { pane.move(p) }
                    }
                    .onEnded { v in touching = false; pane.up(toCanvas(v.location)) }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in pane.pinch(v.magnification) }
                    .onEnded { _ in pane.pinchEnded() }
            )
            .offset(x: (geo.size.width - wPt) / 2, y: (geo.size.height - hPt) / 2)
            .accessibilityElement()
            .accessibilityLabel(Text("m-cas \(pane.screen.title.lowercased())"))
        }
        .clipped()
    }
}
