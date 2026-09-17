import SwiftUI

/// Android ParamTile equivalent: drag vertically one camera enum detent at a
/// time, coalesce each crossed detent in the model, and dim read-only values.
struct RemoteExposureTile: View {
    let field: RemoteExposureField
    let descriptor: RemotePropertyDescriptor?
    let onOpenList: () -> Void
    let onCommit: (UInt64) -> Void
    var onDetent: (() -> Void)? = nil
    var autoEnabled: Bool? = nil
    var autoToggle: (() -> Void)? = nil
    var autoBusy = false
    var effectiveISO: UInt64? = nil
    var rowHeight: CGFloat = 18

    @State private var position: CGFloat = 0
    @State private var dragStart: CGFloat = 0
    @State private var dragging = false
    @State private var lastFeedbackIndex: Int?

    private var values: [UInt64] { descriptor?.values ?? [] }
    private var selectedIndex: Int {
        guard let current = descriptor?.current, let exact = values.firstIndex(of: current) else { return 0 }
        return exact
    }
    private var writable: Bool { descriptor?.writable == true && !values.isEmpty && autoEnabled != true }
    private var downSign: CGFloat {
        guard let descriptor else { return -1 }
        return CGFloat(RemoteExposureParameters.downStepSign(for: descriptor.property, values: values))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ZTransferColors.secondaryText)
                    .opacity(dragging ? 0 : 1)
                GeometryReader { proxy in
                    let center = proxy.size.height / 2
                    ZStack {
                        if autoEnabled == true {
                            Text(effectiveISO.map(String.init) ?? "—")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ZTransferColors.primaryText)
                        } else if let descriptor {
                            let index = min(max(Int(position.rounded()), 0), max(values.count - 1, 0))
                            Text(displayValue(descriptor, raw: !dragging || values.isEmpty ? descriptor.current : values[index]))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ZTransferColors.primaryText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("—")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ZTransferColors.secondaryText)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .onTapGesture { if writable { onOpenList() } }
                    .frame(height: 32)
                    .position(x: proxy.size.width / 2, y: center)
                }
                .frame(height: 32)
            }
            if let autoEnabled, let autoToggle {
                Button("AUTO", action: autoToggle)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ZTransferColors.secondaryText)
                    .padding(.horizontal, 5).frame(height: 17)
                    .background(autoEnabled ? ZTransferColors.accentYellow.opacity(0.24) : Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.9), lineWidth: 1))
                    .disabled(autoBusy)
                    .padding(4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
        .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.96), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        .opacity(writable || autoToggle != nil || descriptor == nil ? 1 : 0.48)
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
                if !dragging {
                    dragging = true
                    dragStart = CGFloat(selectedIndex)
                    lastFeedbackIndex = selectedIndex
                }
                let raw = dragStart + downSign * value.translation.height / max(rowHeight, 1)
                position = min(max(raw, 0), CGFloat(max(values.count - 1, 0)))
                let index = Int(position.rounded())
                if index != lastFeedbackIndex, values.indices.contains(index) {
                    lastFeedbackIndex = index
                    onDetent?()
                    onCommit(values[index])
                }
            }
            .onEnded { value in
                guard writable else { return }
                let raw = dragStart + downSign * value.translation.height / max(rowHeight, 1)
                let target = Int(min(max(raw, 0), CGFloat(values.count - 1)).rounded())
                dragging = false
                lastFeedbackIndex = nil
                withAnimation(ZTransferMotion.standard) { position = CGFloat(target) }
            }
    }

    private func displayValue(_ descriptor: RemotePropertyDescriptor, raw: UInt64) -> String {
        let value = RemoteExposureParameters.format(descriptor.property, raw: raw)
        switch field {
        case .exposureCompensation:
            return value.replacingOccurrences(of: "EV", with: "")
        case .iso:
            return value.replacingOccurrences(of: "ISO", with: "")
        case .aperture, .shutter:
            return value
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
