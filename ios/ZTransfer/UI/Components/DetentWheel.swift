import SwiftUI

/// iOS implementation of Android `ReleaseCommitWheel`.
/// The selected value is previewed locally while dragging and committed only
/// when the gesture ends. Short wheels advance on tap and never steal scrolling.
struct DetentWheel<Option: Hashable>: View {
    let label: String
    let options: [Option]
    let selected: Option
    let optionLabel: (Option) -> String
    let onCommit: (Option) -> Void
    var onDetent: () -> Void = {}
    var rowHeight: CGFloat = 18
    var wheelHeight: CGFloat = 50
    var enabled = true

    @State private var position: CGFloat
    @State private var dragStart: CGFloat
    @State private var dragging = false

    init(label: String, options: [Option], selected: Option,
         optionLabel: @escaping (Option) -> String,
         onCommit: @escaping (Option) -> Void,
         rowHeight: CGFloat = 18, wheelHeight: CGFloat = 50,
         enabled: Bool = true, onDetent: @escaping () -> Void = {}) {
        precondition(!options.isEmpty, "DetentWheel requires at least one option")
        self.label = label; self.options = options; self.selected = selected
        self.optionLabel = optionLabel; self.onCommit = onCommit
        self.rowHeight = rowHeight; self.wheelHeight = wheelHeight
        self.enabled = enabled; self.onDetent = onDetent
        let initial = options.firstIndex(of: selected) ?? 0
        _position = State(initialValue: CGFloat(initial))
        _dragStart = State(initialValue: CGFloat(initial))
    }

    private var selectedIndex: Int { options.firstIndex(of: selected) ?? 0 }
    private var canDrag: Bool { options.count > 3 }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .zTransferText(size: ZTransferMetrics.caption, weight: .semibold)
                .opacity(dragging ? 0 : 1)
                .animation(.easeOut(duration: dragging ? 0.09 : 0.18), value: dragging)
            GeometryReader { proxy in
                let center = proxy.size.height / 2
                ZStack {
                    RoundedRectangle(cornerRadius: min(13, rowHeight / 2 + 5))
                        .fill(ZTransferColors.accentBlue.opacity(0.10))
                        .frame(height: rowHeight)
                    wheelRows(center: center)
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(gesture)
            }
            .frame(height: wheelHeight)
        }
        .opacity(enabled ? 1 : 0.48)
        .onChange(of: selected) { value in
            guard let newIndex = options.firstIndex(of: value), !dragging else { return }
            withAnimation(ZTransferMotion.standard) { position = CGFloat(newIndex) }
        }
    }

    @ViewBuilder
    private func wheelRows(center: CGFloat) -> some View {
        let centerIndex = Int(position.rounded()).clamped(to: 0...(options.count - 1))
        let indices: [Int] = dragging
            ? Array(max(0, Int(floor(position)) - 1)...min(options.count - 1, Int(ceil(position)) + 1))
            : [centerIndex]
        ForEach(indices, id: \.self) { index in
            let distance = abs(CGFloat(index) - position)
            Text(optionLabel(options[index]))
                .zTransferText(size: distance < 0.5 ? ZTransferMetrics.body : ZTransferMetrics.caption,
                               weight: distance < 0.5 ? .semibold : .regular)
                .opacity(distance < 0.5 ? 1 : 0.38)
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                .offset(y: center - rowHeight / 2 + (CGFloat(index) - position) * rowHeight)
        }
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: canDrag ? 2 : .infinity)
            .onChanged { value in
                guard enabled, canDrag else { return }
                if !dragging { dragging = true; dragStart = CGFloat(selectedIndex) }
                let raw = dragStart - value.translation.height / max(rowHeight, 1)
                let next = min(max(raw, 0), CGFloat(max(options.count - 1, 0)))
                let oldDetent = Int(position.rounded())
                position = next
                let newDetent = Int(next.rounded())
                if newDetent != oldDetent { onDetent() }
            }
            .onEnded { value in
                guard enabled, canDrag else { return }
                let raw = dragStart - value.translation.height / max(rowHeight, 1)
                let target = Int(min(max(raw, 0), CGFloat(max(options.count - 1, 0))).rounded())
                dragging = false
                withAnimation(ZTransferMotion.standard) { position = CGFloat(target) }
                if options.indices.contains(target), target != selectedIndex { onCommit(options[target]) }
            }
            .simultaneously(with: TapGesture().onEnded {
                guard enabled, !canDrag, !options.isEmpty else { return }
                let target = (selectedIndex + 1) % options.count
                guard target != selectedIndex else { return }
                onDetent()
                withAnimation(ZTransferMotion.standard) { position = CGFloat(target) }
                onCommit(options[target])
            })
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
