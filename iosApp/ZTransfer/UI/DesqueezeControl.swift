import SwiftUI
import ZTransferShared

/// iOS presentation adapter for the shared desqueeze values. The actual frame transform belongs
/// to the camera preview host; this control only exposes the same click cycle and label policy.
@MainActor
final class IOSDesqueezeControlModel: ObservableObject {
    @Published private(set) var multiplier: Float = 1

    var displayLabel: String? { DesqueezePolicy.shared.displayLabel(value: multiplier) }
    var isActive: Bool { displayLabel != nil }

    func advance() {
        multiplier = DesqueezePolicy.shared.next(value: multiplier)
    }

    func setMultiplier(_ value: Float) {
        multiplier = DesqueezePolicy.shared.normalized(value: value)
    }
}

@MainActor
struct IOSDesqueezeButton: View {
    @ObservedObject var model: IOSDesqueezeControlModel

    var body: some View {
        Button(action: model.advance) {
            Group {
                if let label = model.displayLabel {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(model.isActive ? Color.accentColor : .secondary)
            .frame(width: 48, height: 48)
            .background(.ultraThinMaterial, in: Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.30), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.18), value: model.displayLabel)
        .accessibilityLabel("反挤压")
        .accessibilityValue(model.displayLabel ?? "默认")
    }
}
