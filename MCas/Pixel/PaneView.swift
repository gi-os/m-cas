import SwiftUI

/// A pixel screen, scaled up with no smoothing, redrawn 15 times a second.
struct PaneView: View {
    @ObservedObject var pane: Pane
    @ObservedObject var machine = Machine.shared
    @State private var touching = false

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / CGFloat(PixelCanvas.W), geo.size.height / CGFloat(PixelCanvas.H))
            let w = CGFloat(PixelCanvas.W) * scale, h = CGFloat(PixelCanvas.H) * scale
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { tl in
                if let img = pane.render(at: tl.date.timeIntervalSinceReferenceDate) {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: w, height: h)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        let p = CGPoint(x: v.location.x / scale, y: v.location.y / scale)
                        if !touching { touching = true; pane.down(p) } else { pane.move(p) }
                    }
                      .onEnded { v in touching = false; pane.up(CGPoint(x: v.location.x / scale, y: v.location.y / scale)) }
            )
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .accessibilityElement()
            .accessibilityLabel(Text("m-cas \(pane.screen.title.lowercased())"))
        }
    }
}
