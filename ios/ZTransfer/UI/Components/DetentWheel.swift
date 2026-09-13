import SwiftUI
import UIKit

/// Shared wheel mirroring Android ReleaseCommitWheel. Short lists advance on
/// tap; long lists preview while dragging and commit only after release.
struct DetentWheel<Option: Hashable>: View {
    let label: String
    let options: [Option]
    let selected: Option
    let optionLabel: (Option) -> String
    let onCommit: (Option) -> Void
    var rowHeight: CGFloat = 18
    var wheelHeight: CGFloat = 50
    var enabled = true
    var readOnly = false
    var cornerRadius: CGFloat = 13
    var optionMaxLines = 1
    var optionFontSize: CGFloat = 14
    var optionFontWeight: Font.Weight? = nil
    var accentColor: Color? = nil
    var emphasized = false
    var showEmphasisBorder = true
    var showDragHint = true
    var onDetent: () -> Void = {}
    var onActivated: (() -> Void)? = nil
    var onLongClick: (() -> Void)? = nil
    var centerIcon: ((Color) -> AnyView)? = nil
    var favoriteOption: (Option) -> Bool = { _ in false }
    var favoriteIconColor: Color? = nil
    var ambientEffectColor: Color? = nil
    var ambientEffectAlpha: Double = 0
    @State private var position: CGFloat
    @State private var dragStart: CGFloat
    @State private var dragging = false
    @State private var suppressNextTap = false
    @GestureState private var gestureActive = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    init(label: String, options: [Option], selected: Option,
         optionLabel: @escaping (Option) -> String,
         onCommit: @escaping (Option) -> Void,
         rowHeight: CGFloat = 18, wheelHeight: CGFloat = 50,
         enabled: Bool = true, readOnly: Bool = false,
         cornerRadius: CGFloat = 13, optionMaxLines: Int = 1,
         optionFontSize: CGFloat = 14, optionFontWeight: Font.Weight? = nil,
         accentColor: Color? = nil, emphasized: Bool = false,
         showEmphasisBorder: Bool = true, showDragHint: Bool = true,
         onDetent: @escaping () -> Void = {}, onActivated: (() -> Void)? = nil,
         onLongClick: (() -> Void)? = nil,
         centerIcon: ((Color) -> AnyView)? = nil,
         favoriteOption: @escaping (Option) -> Bool = { _ in false },
         favoriteIconColor: Color? = nil, ambientEffectColor: Color? = nil,
         ambientEffectAlpha: Double = 0) {
        precondition(!options.isEmpty, "DetentWheel requires at least one option")
        self.label = label; self.options = options; self.selected = selected
        self.optionLabel = optionLabel; self.onCommit = onCommit
        self.rowHeight = rowHeight; self.wheelHeight = wheelHeight
        self.enabled = enabled; self.readOnly = readOnly; self.cornerRadius = cornerRadius
        self.optionMaxLines = optionMaxLines; self.optionFontSize = optionFontSize
        self.optionFontWeight = optionFontWeight; self.accentColor = accentColor
        self.emphasized = emphasized; self.showEmphasisBorder = showEmphasisBorder
        self.showDragHint = showDragHint; self.onDetent = onDetent
        self.onActivated = onActivated; self.onLongClick = onLongClick
        self.centerIcon = centerIcon; self.favoriteOption = favoriteOption
        self.favoriteIconColor = favoriteIconColor; self.ambientEffectColor = ambientEffectColor
        self.ambientEffectAlpha = ambientEffectAlpha
        let initial = options.firstIndex(of: selected) ?? 0
        _position = State(initialValue: CGFloat(initial)); _dragStart = State(initialValue: CGFloat(initial))
    }

    private var selectedIndex: Int { options.firstIndex(of: selected) ?? 0 }
    private var canDrag: Bool { options.count > 3 }
    private var accent: Color { accentColor ?? ZTransferColors.accentBlue }

    var body: some View {
        GeometryReader { proxy in
            let center = proxy.size.height / 2
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(emphasized ? 0.86 : 0.74))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke((dragging || (emphasized && showEmphasisBorder) ? accent : ZTransferColors.primaryText)
                            .opacity(dragging || emphasized ? 0.85 : 0.10), lineWidth: dragging ? 1.5 : 1))
                if let ambientEffectColor, ambientEffectAlpha > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(ambientEffectColor.opacity(ambientEffectAlpha)).allowsHitTesting(false)
                }
                wheelRows(center: center)
                if !label.isEmpty {
                    Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(accent.opacity(0.10), in: UnevenRoundedRectangle(bottomTrailingRadius: 5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(dragging ? 0 : 1)
                }
                if canDrag && showDragHint {
                    Text("↕︎").font(.system(size: 10)).foregroundStyle(ZTransferColors.secondaryText.opacity(0.38))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 7).padding(.bottom, 4).opacity(dragging ? 0 : 1)
                }
            }
            .contentShape(Rectangle())
            // The workbench is itself a vertical ScrollView. Give a wheel's
            // drag first refusal so its detent tracks the finger instead of
            // waiting for the parent scroll view to yield.
            .highPriorityGesture(dragGesture)
            // A one-detent control is an Android combinedClickable action, not
            // a wheel. Use a high-priority gesture so the surrounding workbench
            // ScrollView cannot consume the tap before onActivated runs.
            .highPriorityGesture(TapGesture().onEnded {
                guard !canDrag else { return }
                activate()
            })
            .simultaneousGesture(tapGesture).simultaneousGesture(longPressGesture)
            .animation(.easeInOut(duration: dragging ? 0.09 : 0.18), value: dragging)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(height: wheelHeight).opacity(enabled ? 1 : 0.48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label.isEmpty ? "拨轮" : label))
        .accessibilityValue(Text(optionLabel(options[selectedIndex]) + (favoriteOption(options[selectedIndex]) ? "，已收藏" : "")))
        .accessibilityHint(Text(readOnly ? "只读" : (canDrag ? "上下拖动调整，点击切换" : "点击切换")))
        .accessibilityAddTraits(.isButton)
        .onChange(of: selected) { value in sync(value: value) }
        .onChange(of: options) { _ in sync(value: selected) }
        .onChange(of: gestureActive) { active in
            // GestureState resets automatically when SwiftUI cancels a drag
            // (for example when a parent ScrollView takes ownership). A normal
            // release clears `dragging` in onEnded first, so only cancellation
            // reaches this rollback path.
            if !active, dragging {
                dragging = false
                position = CGFloat(selectedIndex)
            }
        }
    }

    @ViewBuilder private func wheelRows(center: CGFloat) -> some View {
        let centerIndex = min(max(Int(position.rounded()), 0), options.count - 1)
        let indices = dragging ? Array(max(0, Int(floor(position)) - 1)...min(options.count - 1, Int(ceil(position)) + 1)) : [centerIndex]
        ForEach(indices, id: \.self) { index in
            let distance = abs(CGFloat(index) - position); let active = distance < 0.5
            let color = (emphasized && active ? accent : ZTransferColors.primaryText).opacity(active ? 1 : 0.38)
            HStack(spacing: 4) {
                if favoriteOption(options[index]) { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle((favoriteIconColor ?? accent).opacity(active ? 1 : 0.38)) }
                if let centerIcon { centerIcon(color) }
                Text(optionLabel(options[index])).font(.system(size: active ? optionFontSize : max(12, optionFontSize - 2), weight: optionFontWeight ?? (active ? .semibold : .regular))).lineLimit(optionMaxLines).multilineTextAlignment(.center).foregroundStyle(color)
            }
            .frame(maxWidth: .infinity).frame(height: rowHeight)
            // ZStack already centers each row. Only move neighboring rows by
            // their detent delta; adding a second center offset puts the value
            // at the bottom of the wheel.
            .offset(y: (CGFloat(index) - position) * rowHeight)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: canDrag ? 2 : .infinity)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard enabled, !readOnly, canDrag else { return }
                if !dragging { dragging = true; dragStart = CGFloat(selectedIndex) }
                let next = min(max(dragStart - value.translation.height / max(rowHeight, 1), 0), CGFloat(options.count - 1))
                if Int(next.rounded()) != Int(position.rounded()) { emitDetent() }; position = next
            }
            .onEnded { value in
                guard enabled, !readOnly, canDrag else {
                    dragging = false
                    position = CGFloat(selectedIndex)
                    return
                }
                let raw = dragStart - value.translation.height / max(rowHeight, 1)
                let target = min(max(Int(raw.rounded()), 0), options.count - 1); dragging = false
                withAnimation(ZTransferMotion.standard) { position = CGFloat(target) }
                if target != selectedIndex { onCommit(options[target]) }
            }
    }

    private var tapGesture: some Gesture {
        TapGesture().onEnded {
            // Android combinedClickable keeps click behavior even when the
            // same wheel also supports vertical dragging.
            guard canDrag else { return }
            activate()
        }
    }

    private func activate() {
        guard enabled, !readOnly else { return }
        if suppressNextTap { suppressNextTap = false; return }
        if let onActivated { onActivated(); return }
        let target = (selectedIndex + 1) % options.count
        guard target != selectedIndex else { return }
        emitDetent()
        withAnimation(ZTransferMotion.standard) { position = CGFloat(target) }
        onCommit(options[target])
    }

    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            guard enabled, !readOnly, onLongClick != nil else { return }
            suppressNextTap = true
            onLongClick?()
            // SwiftUI does not expose combinedClickable's consumed-up event;
            // clear the guard after the gesture sequence so a long press can
            // never suppress a later, unrelated tap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                suppressNextTap = false
            }
        }
    }

    private func sync(value: Option) {
        guard !dragging else { return }
        // Android falls back to the first detent when a restored value is no
        // longer present in a rebuilt option list; never leave the wheel on
        // the previous (often last) position.
        let index = options.firstIndex(of: value) ?? 0
        withAnimation(ZTransferMotion.standard) { position = CGFloat(index) }
    }

    private func emitDetent() {
        guard hapticsEnabled else { return }
        onDetent()
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}
