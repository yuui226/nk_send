#if DEBUG
import SwiftUI

/// Isolated UI automation host for the production Button primitive/style.
/// Only selected by an explicit test launch argument; absent from Release.
struct ButtonInteractionTestHarness: View {
    @State private var clicks = 0
    @State private var scrollClicks = 0
    @State private var enabled = true
    @State private var active = false
    @State private var trace = "[]"

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Clear trace") { ButtonInteractionTrace.reset() }
                    .accessibilityIdentifier("clear-trace")
                Button("Read trace") { trace = ButtonInteractionTrace.snapshot() }
                    .accessibilityIdentifier("read-trace")
            }.buttonStyle(.plain)
            Text("Trace").accessibilityValue(trace).accessibilityIdentifier("interaction-trace")
            Text("\(clicks)").accessibilityIdentifier("button-action-count")
            Text("\(scrollClicks)").accessibilityIdentifier("scroll-action-count")
            Button {
                clicks += 1
                active.toggle()
            } label: {
                Text("Material action").frame(width: 220, height: 52)
            }
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 26, active: active, textureSeed: 1001))
            .disabled(!enabled)
            .accessibilityIdentifier("material-action")

            Button("Toggle enabled") { enabled.toggle() }
                .buttonStyle(.plain)
                .accessibilityIdentifier("toggle-enabled")

            ScrollView {
                VStack(spacing: 20) {
                    Button { scrollClicks += 1 } label: {
                        Text("Scrollable action").frame(width: 220, height: 52)
                    }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 26, textureSeed: 1002))
                    .accessibilityIdentifier("scrollable-action")
                    ForEach(0..<30) { index in
                        Text("Row \(index)").frame(height: 40)
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("interaction-scroll")
        }
        .padding(24)
        .background { ButtonInteractionTouchTrace() }
        .onAppear { ButtonInteractionTrace.enabled = true; ButtonInteractionTrace.reset() }
        .onDisappear { ButtonInteractionTrace.enabled = false }
    }
}
#endif
