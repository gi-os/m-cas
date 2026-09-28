import SwiftUI

/// One pixel screen on a regular iPhone and on the iPhone Duo's outer display. On a wide
/// window — the Duo's inner display, landscape, or a wide side-by-side slot — the deck stays
/// on the left and the shelf, clips and label editor share the right.
struct RootView: View {
    @StateObject private var main = Pane(screen: .deck)
    @StateObject private var side = Pane(screen: .clips)
    @ObservedObject private var machine = Machine.shared
    @FocusState private var editingName: Bool
    @Environment(\.scenePhase) private var phase

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 0.8
            ZStack {
                Color(Ink.ink).ignoresSafeArea()
                if wide {
                    HStack(spacing: 12) {
                        PaneView(pane: main)
                        PaneView(pane: side)
                    }
                    .padding(12)
                } else {
                    PaneView(pane: main)
                }
                TextField("", text: $machine.nameDraft)
                    .focused($editingName)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { machine.renameCurrent(machine.nameDraft) }
                    .onChange(of: machine.nameDraft) { _, v in if v.count > 14 { machine.nameDraft = String(v.prefix(14)) } }
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            .onChange(of: wide) { _, isWide in
                if isWide, main.screen != .deck { side.screen = main.screen; main.screen = .deck }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            machine.start()
            main.onEditName = { editingName = true }
            side.onEditName = { editingName = true }
        }
        .onChange(of: editingName) { _, on in if !on { machine.renameCurrent(machine.nameDraft) } }
        .onChange(of: phase) { _, p in if p != .active { machine.savePosition() } }
    }
}
