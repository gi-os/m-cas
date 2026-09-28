import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MCasWidgets: WidgetBundle {
    var body: some Widget { RecordingLiveActivity() }
}

private enum Tape {
    static let red = Color(red: 0.878, green: 0.251, blue: 0.251)
    static let cream = Color(red: 0.973, green: 0.941, blue: 0.784)
    static let grey = Color(red: 0.659, green: 0.659, blue: 0.722)
    static let ink = Color(red: 0.031, green: 0.031, blue: 0.063)
    static func pixel(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "Silkscreen-Bold" : "Silkscreen-Regular", size: size) }
}

/// Two tiny reels and a window, drawn with rectangles so they stay crisp.
private struct MiniCassette: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Tape.cream)
            RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.16, green: 0.09, blue: 0.06)).frame(width: 18, height: 7).offset(y: 1)
            HStack(spacing: 5) {
                Circle().fill(Color(red: 0.63, green: 0.41, blue: 0.19)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.63, green: 0.41, blue: 0.19)).frame(width: 5, height: 5)
            }
            .offset(y: 1)
        }
        .frame(width: 26, height: 17)
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { ctx in
            HStack(spacing: 14) {
                MiniCassette().scaleEffect(1.6).frame(width: 44, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(Tape.red).frame(width: 8, height: 8)
                        Text("REC").font(Tape.pixel(12, bold: true)).foregroundStyle(Tape.red)
                        Text(ctx.attributes.tape.uppercased()).font(Tape.pixel(12, bold: true)).foregroundStyle(Tape.cream).lineLimit(1)
                    }
                    Text(ctx.state.place.uppercased()).font(Tape.pixel(10)).foregroundStyle(Tape.grey).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(timerInterval: ctx.state.started...Date.distantFuture, countsDown: false)
                        .font(Tape.pixel(16)).monospacedDigit().foregroundStyle(Tape.red).multilineTextAlignment(.trailing)
                    Button(intent: StopRecordingIntent()) {
                        Text("STOP").font(Tape.pixel(10, bold: true)).foregroundStyle(Tape.ink)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Tape.cream, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .activityBackgroundTint(Tape.ink)
            .activitySystemActionForegroundColor(Tape.cream)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) { MiniCassette(); Text("REC").font(Tape.pixel(12, bold: true)).foregroundStyle(Tape.red) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: ctx.state.started...Date.distantFuture, countsDown: false)
                        .font(Tape.pixel(14)).monospacedDigit().foregroundStyle(Tape.red).frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ctx.attributes.tape.uppercased()).font(Tape.pixel(12, bold: true)).foregroundStyle(Tape.cream).lineLimit(1)
                            Text(ctx.state.place.uppercased()).font(Tape.pixel(10)).foregroundStyle(Tape.grey).lineLimit(1)
                        }
                        Spacer()
                        Button(intent: StopRecordingIntent()) {
                            Text("STOP").font(Tape.pixel(11, bold: true)).foregroundStyle(Tape.ink)
                                .padding(.horizontal, 12).padding(.vertical, 6).background(Tape.cream, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) { Circle().fill(Tape.red).frame(width: 7, height: 7); MiniCassette().scaleEffect(0.8) }
            } compactTrailing: {
                Text(timerInterval: ctx.state.started...Date.distantFuture, countsDown: false)
                    .font(Tape.pixel(11)).monospacedDigit().foregroundStyle(Tape.red).frame(maxWidth: 44)
            } minimal: {
                Circle().fill(Tape.red).frame(width: 9, height: 9)
            }
            .keylineTint(Tape.red)
        }
    }
}
