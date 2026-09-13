import SwiftUI

/// Android ParamTile equivalent: drag vertically one camera enum detent at a
/// time, commit only on release, and keep read-only descriptors visibly dimmed.
struct RemoteExposureTile: View {
    let field: RemoteExposureField
    let descriptor: RemotePropertyDescriptor?
    let onOpenList: () -> Void
    let onCommit: (UInt64) -> Void
    var autoEnabled: Bool? = nil
    var autoToggle: (() -> Void)? = nil
    var rowHeight: CGFloat = 18

    @State private var position: CGFloat = 0
    @State private var dragStart: CGFloat = 0
    @State private var dragging = false

    private var values: [UInt64] { descriptor?.values ?? [] }
    private var selectedIndex: Int {
        guard let current = descriptor?.current, let exact = values.firstIndex(of: current) else { return 0 }
        return exact
    }
    private var writable: Bool { descriptor?.writable == true && !values.isEmpty }
    private var downSign: CGFloat {
        guard let descriptor else { return -1 }
        return CGFloat(RemoteExposureParameters.downStepSign(for: descriptor.property, values: values))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(dragging ? 0 : 1)
                GeometryReader { proxy in
                let center = proxy.size.height / 2
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.10))
                        .frame(height: rowHeight)
                    if let descriptor {
                        let index = min(max(Int(position.rounded()), 0), max(values.count - 1, 0))
                        Text(RemoteExposureParameters.format(descriptor.property,
                                                              raw: values.isEmpty ? descriptor.current : values[index]))
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("—").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .onTapGesture { if descriptor != nil { onOpenList() } }
                .frame(height: 42)
                .position(x: proxy.size.width / 2, y: center)
                }
                .frame(height: 42)
            }
            if let autoEnabled, let autoToggle {
                Button("AUTO", action: autoToggle)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(autoEnabled ? .black : .white.opacity(0.7))
                    .padding(.horizontal, 5).frame(height: 17)
                    .background(autoEnabled ? Color.yellow.opacity(0.9) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .disabled(!writable)
                    .padding(4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .opacity(writable || descriptor == nil ? 0.72 : 0.42)
        .onAppear { position = CGFloat(selectedIndex) }
        .onChange(of: descriptor?.current) { _ in
            guard !dragging else { return }
            withAnimation(ZTransferMotion.standard) { position = CGFloat(selectedIndex) }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: writable ? 2 : .infinity)
            .onChanged { value in
                guard writable else { return }
                if !dragging { dragging = true; dragStart = CGFloat(selectedIndex) }
                let raw = dragStart + downSign * value.translation.height / max(rowHeight, 1)
                position = min(max(raw, 0), CGFloat(max(values.count - 1, 0)))
            }
            .onEnded { value in
                guard writable else { return }
                let raw = dragStart + downSign * value.translation.height / max(rowHeight, 1)
                let target = Int(min(max(raw, 0), CGFloat(values.count - 1)).rounded())
                dragging = false
                withAnimation(ZTransferMotion.standard) { position = CGFloat(target) }
                if values.indices.contains(target), values[target] != descriptor?.current { onCommit(values[target]) }
            }
    }
}

private extension RemoteExposureField {
    var label: String {
        switch self {
        case .exposureCompensation: return "EV"
        case .iso: return "ISO"
        case .aperture: return "f"
        case .shutter: return "S"
        }
    }
}
