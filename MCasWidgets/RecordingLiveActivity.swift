import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MCasWidgets: WidgetBundle {
    var body: some Widget { RecordingLiveActivity() }
}

/// The m-cas palette, as in the app.
private enum P {
    static func hex(_ s: String) -> Color {
        let v = UInt32(s.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xf8d848
        return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    static let ink = hex("080810"), navy = hex("181830"), blue = hex("283058")
    static let red = hex("e04040"), cream = hex("f8f0c8"), tan = hex("e0c890"), shell = hex("a88860")
    static let brown = hex("a06830"), dark = hex("583020"), window = hex("281810")
    static let mint = hex("88d8b0"), grey = hex("a8a8b8")
    static func px(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "Silkscreen-Bold" : "Silkscreen-Regular", size: size) }
}

/// Diagonal bands, the "bands" label pattern.
private struct Bands: Shape {
    var step: CGFloat = 8
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = -r.height
        while x < r.width {
            p.move(to: CGPoint(x: r.minX + x, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + x + step / 2, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + x + step / 2 + r.height, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + x + r.height, y: r.minY))
            p.closeSubpath()
            x += step
        }
        return p
    }
}

/// A row of checker "dither" along the top edge.
private struct Dither: Shape {
    var cell: CGFloat = 2
    func path(in r: CGRect) -> Path {
        var p = Path()
        var y: CGFloat = 0
        var row = 0
        while y < r.height {
            var x: CGFloat = row % 2 == 0 ? 0 : cell
            while x < r.width { p.addRect(CGRect(x: r.minX + x, y: r.minY + y, width: cell, height: cell)); x += cell * 2 }
            y += cell; row += 1
        }
        return p
    }
}

/// The tape, drawn: shell, label in the tape's colors, window and two reels.
private struct Cassette: View {
    let a: Color, b: Color, name: String
    var width: CGFloat = 107
    var showName = true
    var body: some View {
        let s = width / 107
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5 * s).fill(P.tan)
            Rectangle().fill(P.shell).frame(height: 6 * s).offset(y: 62 * s)
            ZStack(alignment: .top) {
                a
                Bands(step: 8 * s).fill(b)
                if showName {
                    HStack {
                        Text(name.uppercased()).font(P.px(6 * s)).foregroundStyle(P.dark).lineLimit(1)
                        Spacer(minLength: 2)
                        Text("A").font(P.px(6 * s, bold: true)).foregroundStyle(P.red)
                    }
                    .padding(.horizontal, 4 * s)
                    .frame(height: 11 * s)
                    .background(P.cream)
                }
            }
            .frame(width: 91 * s, height: 42 * s)
            .clipped()
            .overlay(Rectangle().stroke(P.dark, lineWidth: 1.5 * s))
            .offset(x: 8 * s, y: 6 * s)
            Capsule().fill(P.window).overlay(Capsule().stroke(P.dark, lineWidth: 1.5 * s))
                .frame(width: 63 * s, height: 22 * s).offset(x: 22 * s, y: 27 * s)
            reel(big: true, s).offset(x: 26 * s, y: 29 * s)
            reel(big: false, s).offset(x: 69 * s, y: 33 * s)
        }
        .frame(width: width, height: 68 * s)
        .overlay(RoundedRectangle(cornerRadius: 5 * s).stroke(P.dark, lineWidth: 1.5 * s))
    }

    private func reel(big: Bool, _ s: CGFloat) -> some View {
        let d = (big ? 18 : 10) * s
        return ZStack {
            Circle().fill(P.brown).frame(width: d, height: d)
            Circle().fill(P.cream).frame(width: 8 * s, height: 8 * s).overlay(Circle().stroke(P.dark, lineWidth: 1.5 * s))
        }
        .frame(width: 18 * s, height: 18 * s)
    }
}

/// The Stop key: a cream tape-deck key with a dark lip.
private struct StopKey: View {
    var tall = false
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Group {
                if tall {
                    VStack(spacing: 5) { Rectangle().fill(P.red).frame(width: 13, height: 13); Text("STOP").font(P.px(9, bold: true)) }
                        .frame(width: 64, height: 48)
                } else {
                    HStack(spacing: 6) { Rectangle().fill(P.red).frame(width: 10, height: 10); Text("STOP").font(P.px(10, bold: true)) }
                        .padding(.horizontal, 13).frame(height: 32)
                }
            }
            .foregroundStyle(P.dark)
            .background(RoundedRectangle(cornerRadius: 3).fill(P.cream))
            .background(RoundedRectangle(cornerRadius: 3).fill(P.dark).offset(y: 3))
        }
        .buttonStyle(.plain)
    }
}

private func timer(_ start: Date) -> Text {
    Text(timerInterval: start...Date.distantFuture, countsDown: false)
}

private func split(_ place: String) -> (String, String?) {
    let parts = place.components(separatedBy: ", ")
    guard parts.count > 1 else { return (place, nil) }
    return (parts[0], parts.dropFirst().joined(separator: ", "))
}

private func mmss(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { ctx in
            LockScreen(ctx: ctx)
                .activityBackgroundTint(P.ink)
                .activitySystemActionForegroundColor(P.cream)
        } dynamicIsland: { ctx in
            let a = P.hex(ctx.attributes.labelA), b = P.hex(ctx.attributes.labelB)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        Cassette(a: a, b: b, name: "", width: 42, showName: false)
                        Rectangle().fill(ctx.state.saved ? P.mint : P.red).frame(width: 6, height: 6)
                        Text(ctx.state.saved ? "SAVED" : "REC").font(P.px(10, bold: true)).foregroundStyle(ctx.state.saved ? P.mint : P.red)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if ctx.state.saved { Text(mmss(ctx.state.seconds)) } else { timer(ctx.state.started) }
                    }
                    .font(P.px(22)).monospacedDigit().foregroundStyle(ctx.state.saved ? P.mint : P.red)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 110, alignment: .trailing).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(ctx.attributes.tape.uppercased()) · CLIP \(ctx.attributes.clip)").font(P.px(12, bold: true)).foregroundStyle(P.cream).lineLimit(1)
                            Text(split(ctx.state.place).0.uppercased()).font(P.px(9)).foregroundStyle(P.mint).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if !ctx.state.saved { StopKey() }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Rectangle().fill(ctx.state.saved ? P.mint : P.red).frame(width: 6, height: 6)
                    Circle().fill(a).frame(width: 8, height: 8).overlay(Circle().stroke(P.dark, lineWidth: 1))
                    Circle().fill(a).frame(width: 8, height: 8).overlay(Circle().stroke(P.dark, lineWidth: 1))
                }
            } compactTrailing: {
                Group {
                    if ctx.state.saved { Text(mmss(ctx.state.seconds)) } else { timer(ctx.state.started) }
                }
                .font(P.px(11)).monospacedDigit().foregroundStyle(ctx.state.saved ? P.mint : P.red).frame(maxWidth: 44)
            } minimal: {
                ZStack {
                    Circle().fill(P.brown).overlay(Circle().stroke(ctx.state.saved ? P.mint : P.red, lineWidth: 2.5))
                    Rectangle().fill(P.cream).frame(width: 4, height: 4)
                }
                .frame(width: 15, height: 15)
            }
            .keylineTint(P.red)
            .widgetURL(URL(string: "mcas://deck"))
        }
    }
}

private struct LockScreen: View {
    let ctx: ActivityViewContext<RecordingAttributes>

    var body: some View {
        let a = P.hex(ctx.attributes.labelA), b = P.hex(ctx.attributes.labelB)
        let place = split(ctx.state.place)
        VStack(spacing: 0) {
            Dither(cell: 2).fill(P.blue).frame(height: 5).background(P.navy)
            if ctx.state.saved {
                HStack(spacing: 12) {
                    Cassette(a: a, b: b, name: ctx.attributes.tape, width: 60, showName: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SAVED TO \(ctx.attributes.tape.uppercased())").font(P.px(11, bold: true)).foregroundStyle(P.mint).lineLimit(1)
                        Text("\(place.0.uppercased()) · \(mmss(ctx.state.seconds))").font(P.px(8)).foregroundStyle(P.cream).lineLimit(1)
                        Text("CLIP \(ctx.attributes.clip)").font(P.px(7)).foregroundStyle(P.grey)
                    }
                    Spacer(minLength: 0)
                    Link(destination: URL(string: "mcas://play?clip=\(ctx.attributes.clip)")!) {
                        HStack(spacing: 6) { Image(systemName: "play.fill").font(.system(size: 10, weight: .black)); Text("PLAY").font(P.px(9, bold: true)) }
                            .foregroundStyle(P.dark).padding(.horizontal, 11).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 3).fill(P.cream))
                            .background(RoundedRectangle(cornerRadius: 3).fill(P.dark).offset(y: 3))
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 13)
            } else {
                VStack(spacing: 9) {
                    HStack(alignment: .center) {
                        Rectangle().fill(P.red).frame(width: 7, height: 7)
                        Text("REC").font(P.px(10, bold: true)).foregroundStyle(P.red)
                        Text("SIDE A · CLIP \(ctx.attributes.clip)").font(P.px(8)).foregroundStyle(P.grey)
                        Spacer(minLength: 0)
                        timer(ctx.state.started).font(P.px(20)).monospacedDigit().foregroundStyle(P.red).multilineTextAlignment(.trailing).frame(maxWidth: 110, alignment: .trailing)
                    }
                    HStack(alignment: .center, spacing: 13) {
                        Cassette(a: a, b: b, name: ctx.attributes.tape, width: 107)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(ctx.attributes.tape.uppercased()).font(P.px(13, bold: true)).foregroundStyle(P.cream).lineLimit(1)
                            Text(place.0.uppercased()).font(P.px(8)).foregroundStyle(P.mint).lineLimit(2)
                            if let hood = place.1 { Text(hood.uppercased()).font(P.px(7)).foregroundStyle(P.grey).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                        StopKey(tall: true)
                    }
                }
                .padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 13)
            }
        }
        .widgetURL(URL(string: "mcas://deck"))
    }
}
