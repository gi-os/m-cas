import SwiftUI
import UIKit

/// One pixel screen on a regular iPhone and on the iPhone Duo's outer display. On a wide
/// window — the Duo's inner display, landscape — the deck stays on the left and the shelf,
/// clips and label editor share the right. The keyboard never changes the layout.
struct RootView: View {
    @StateObject private var main = Pane(screen: Demo.active ? Demo.screen : .deck)
    @StateObject private var side = Pane(screen: .clips)
    @ObservedObject private var machine = Machine.shared
    @FocusState private var editingName: Bool
    /// The name offered when the field opened; the first delete clears it whole.
    @State private var suggestion: String?
    @Environment(\.scenePhase) private var phase

    private var insets: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets ?? scene?.windows.first?.safeAreaInsets ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 0.8
            let ins = insets
            ZStack {
                Color(Ink.ink)
                if wide {
                    HStack(spacing: 0) {
                        PaneView(pane: main, safeTop: ins.top, safeBottom: ins.bottom)
                        PaneView(pane: side, safeTop: ins.top, safeBottom: ins.bottom)
                    }
                } else {
                    PaneView(pane: main, safeTop: ins.top, safeBottom: ins.bottom)
                }
                TextField("", text: $machine.nameDraft)
                    .focused($editingName)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { machine.commitName() }
                    .onChange(of: machine.nameDraft) { old, v in
                        // The suggested name goes with one delete, so you start typing fresh.
                        if let sug = suggestion, v != sug {
                            suggestion = nil
                            if old == sug && v.count == old.count - 1 && old.hasPrefix(v) { machine.nameDraft = ""; return }
                        }
                        if v.count > 24 { machine.nameDraft = String(v.prefix(24)) }
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            .onChange(of: wide) { _, isWide in
                if isWide, main.screen != .deck { side.screen = main.screen; main.screen = .deck }
            }
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            machine.start()
            main.onEditName = { suggestion = machine.nameDraft; editingName = true }
            side.onEditName = { suggestion = machine.nameDraft; editingName = true }
        }
        .onChange(of: editingName) { _, on in if !on { machine.commitName() } }
        .onOpenURL { machine.open($0) }
        .onChange(of: phase) { _, p in if p != .active { machine.savePosition() } }
    }
}
