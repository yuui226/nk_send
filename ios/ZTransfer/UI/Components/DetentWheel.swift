import SwiftUI
import UIKit

/// A control's geometry and typography travel together; compact callers must
/// not shrink only the container while retaining full-size row/badge text.
struct DetentWheelSizing {
    let height: CGFloat
    let rowHeight: CGFloat
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    var fontWeight: Font.Weight? = nil
}

/// Shared wheel mirroring Android ReleaseCommitWheel. Short lists advance on
/// tap; long lists preview while dragging and commit only after release.
struct DetentWheel<Option: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let options: [Option]
    let selected: Option
    let optionLabel: (Option) -> String
    let onCommit: (Option) -> Void
    let rowHeight: CGFloat
    var wheelHeight: CGFloat = 50
    let enabled: Bool
    let readOnly: Bool
    var cornerRadius: CGFloat = 13
    var optionMaxLines = 1
    var optionFontSize: CGFloat = 14
    var optionFontSizeFor: ((Option) -> CGFloat)? = nil
    var optionFontWeight: Font.Weight? = nil
    var optionTextColor: Color? = nil
    var accentColor: Color? = nil
    var emphasized = false
    var showEmphasisBorder = true
    var showDragHint = true
    var onDetent: (() -> Void)? = nil
    var onActivated: (() -> Void)? = nil
    var onLongClick: (() -> Void)? = nil
    var centerIcon: ((Color) -> AnyView)? = nil
    var favoriteOption: (Option) -> Bool = { _ in false }
    var favoriteIconColor: Color? = nil
    var ambientEffectColor: Color? = nil
    var ambientEffectAlpha: Double = 0
    var ambientEffectPulse: NativeAmbientPulse? = nil
    var followsButtonSkin = false
    var prominentPressFeedback = false
    var contentAnchorSpace: AnyHashable? = nil
    var onContentAnchorChange: ((CGRect) -> Void)? = nil
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    @State private var position: CGFloat
    @State private var dragging = false
    @State private var dragSession: DetentWheelDragSession<Option>
    @GestureState private var gestureActive = false
    @GestureState private var pressing = false
    @State private var longPressFeedback = ZTransferLongPressFeedback()
    private let longPressDurationMilliseconds = 450
    // These inputs are immutable for a view value. A new parent configuration
    // recomputes them; local drag frames keep the same accepted selection/key.
    let selectedIndex: Int
    private let gestureConfiguration: DetentWheelConfiguration<Option>

    init(label: String, options: [Option], selected: Option,
         optionLabel: @escaping (Option) -> String,
         onCommit: @escaping (Option) -> Void,
         sizing: DetentWheelSizing? = nil,
         rowHeight: CGFloat = 18, wheelHeight: CGFloat = 50,
         enabled: Bool = true, readOnly: Bool = false,
         cornerRadius: CGFloat = 13, optionMaxLines: Int = 1,
         optionFontSize: CGFloat = 14, optionFontSizeFor: ((Option) -> CGFloat)? = nil, optionFontWeight: Font.Weight? = nil,
         optionTextColor: Color? = nil,
         accentColor: Color? = nil, emphasized: Bool = false,
         showEmphasisBorder: Bool = true, showDragHint: Bool = true,
         onDetent: (() -> Void)? = nil, onActivated: (() -> Void)? = nil,
         onLongClick: (() -> Void)? = nil,
         centerIcon: ((Color) -> AnyView)? = nil,
         favoriteOption: @escaping (Option) -> Bool = { _ in false },
         favoriteIconColor: Color? = nil, ambientEffectColor: Color? = nil,
         ambientEffectAlpha: Double = 0,
         ambientEffectPulse: NativeAmbientPulse? = nil,
         followsButtonSkin: Bool = false,
         prominentPressFeedback: Bool = false,
         contentAnchorSpace: AnyHashable? = nil,
         onContentAnchorChange: ((CGRect) -> Void)? = nil) {
        precondition(!options.isEmpty, "DetentWheel requires at least one option")
        self.label = label; self.options = options; self.selected = selected
        self.optionLabel = optionLabel; self.onCommit = onCommit
        let resolvedRowHeight = sizing?.rowHeight ?? rowHeight
        self.rowHeight = resolvedRowHeight; self.wheelHeight = sizing?.height ?? wheelHeight
        self.enabled = enabled; self.readOnly = readOnly; self.cornerRadius = sizing?.cornerRadius ?? cornerRadius
        self.optionMaxLines = optionMaxLines; self.optionFontSize = sizing?.fontSize ?? optionFontSize
        self.optionFontSizeFor = optionFontSizeFor
        self.optionFontWeight = sizing?.fontWeight ?? optionFontWeight; self.optionTextColor = optionTextColor; self.accentColor = accentColor
        self.emphasized = emphasized; self.showEmphasisBorder = showEmphasisBorder
        self.showDragHint = showDragHint; self.onDetent = onDetent
        self.onActivated = onActivated; self.onLongClick = onLongClick
        self.centerIcon = centerIcon; self.favoriteOption = favoriteOption
        self.favoriteIconColor = favoriteIconColor; self.ambientEffectColor = ambientEffectColor
        self.ambientEffectAlpha = ambientEffectAlpha
        self.ambientEffectPulse = ambientEffectPulse
        self.followsButtonSkin = followsButtonSkin
        self.prominentPressFeedback = prominentPressFeedback
        self.contentAnchorSpace = contentAnchorSpace
        self.onContentAnchorChange = onContentAnchorChange
        let initial = options.firstIndex(of: selected) ?? 0
        selectedIndex = initial
        let configuration = DetentWheelConfiguration(options: options, rowHeight: resolvedRowHeight, enabled: enabled, readOnly: readOnly)
        gestureConfiguration = configuration
        _position = State(initialValue: CGFloat(initial))
        _dragSession = State(initialValue: DetentWheelDragSession(configuration: configuration))
    }

    private var canDrag: Bool { gestureConfiguration.canDrag }
    private var accent: Color { accentColor ?? ZTransferColors.accentBlue }
    private var dark: Bool { colorScheme == .dark }
    private var usesNativeLiquidGlass: Bool {
        followsButtonSkin && ZTransferButtonSkin(storedValue: skinPreset) == .liquidGlass
    }
    private var wheelFill: Color {
        dark ? Color(white: emphasized ? 0.22 : 0.16).opacity(0.94)
             : Color.white.opacity(emphasized ? 0.86 : 0.74)
    }
    private var wheelBorder: Color {
        let active = dragging || (emphasized && showEmphasisBorder)
        return (active ? accent : ZTransferColors.primaryText)
            .opacity(active ? (dark ? 0.9 : 0.85) : (dark ? 0.28 : 0.10))
    }

    var body: some View {
        GeometryReader { proxy in
            let center = proxy.size.height / 2
            let surface = ZStack {
                if usesNativeLiquidGlass {
                    ZTransferButtonMaterialSurface(
                        skin: .liquidGlass,
                        cornerRadius: cornerRadius,
                        active: emphasized,
                        activeColor: accent
                    )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(wheelFill)
                        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(wheelBorder, lineWidth: dragging ? 1.5 : 1))
                }
                if let ambientEffectColor, let ambientEffectPulse {
                    NativeAmbientFill(color: ambientEffectColor, cornerRadius: cornerRadius,
                                      pulse: ambientEffectPulse).allowsHitTesting(false)
                } else if let ambientEffectColor, ambientEffectAlpha > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(ambientEffectColor.opacity(ambientEffectAlpha)).allowsHitTesting(false)
                }
                wheelRows(center: center)
                if !label.isEmpty {
                    // Android ReleaseCommitWheel uses a smaller badge at <=34dp.
                    Text(label)
                        .font(.system(size: wheelHeight <= 34 ? 8 : 9, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(accent)
                        .padding(.horizontal, wheelHeight <= 34 ? 4 : 6)
                        .padding(.vertical, 1)
                        .frame(minHeight: wheelHeight <= 34 ? 11 : 15)
                        .background(accent.opacity(0.10), in: UnevenRoundedRectangle(bottomTrailingRadius: wheelHeight <= 34 ? 4 : 5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(dragging ? 0 : 1)
                }
                if canDrag && showDragHint && enabled && !readOnly {
                    DetentWheelDragHint()
                        .stroke(ZTransferColors.secondaryText.opacity(0.42), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        .frame(width: 6, height: 20)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .opacity(dragging ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
            // Only a real, vertically draggable wheel gets first refusal in
            // the surrounding ScrollView. Short option lists are Android
            // click controls; disabling their drag recognizer lets a
            // press-and-drag continue into the page pager instead of being
            // trapped by a high-priority tap recognizer.
            let interactiveSurface = surface
            .id(gestureConfiguration)
            .contentShape(Rectangle())
            // A normal tap keeps the control clickable without installing a
            // second high-priority recognizer that can delay the enclosing
            // page's vertical drag.
            .gesture(clickGesture)
            // Keep drag and tap on the SAME surface: a high-priority gesture
            // on an inner child cannot outrank the enclosing tap/scroll arena.
            .highPriorityGesture(dragGesture, including: canDrag ? .all : .subviews)
            .simultaneousGesture(pressGesture,
                including: prominentPressFeedback || onLongClick != nil ? .all : .subviews)
            .scaleEffect(prominentPressFeedback && pressing ? 0.96 : 1)
            .brightness(prominentPressFeedback && pressing ? -0.035 : 0)
            .animation(.easeOut(duration: pressing ? 0.07 : 0.16), value: pressing)
            .animation(.easeInOut(duration: dragging ? 0.09 : 0.18), value: dragging)

            if usesNativeLiquidGlass {
                // Native Liquid Glass intentionally draws refraction and its
                // ambient edge just outside the requested shape. The regular
                // wheel clips scrolling rows, but doing that to a button-use
                // wheel makes the system material look like a flat color.
                interactiveSurface
            } else {
                interactiveSurface
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .frame(height: wheelHeight).opacity(enabled ? 1 : 0.48)
        .background {
            if canDrag { WheelDragRegion() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppLocalized.text(label.isEmpty ? "拨轮" : label)))
        .accessibilityValue(Text(AppLocalized.text(optionLabel(options[selectedIndex])) + (favoriteOption(options[selectedIndex]) ? "，已收藏" : "")))
        .accessibilityHint(Text(readOnly ? AppLocalized.text("只读") : AppLocalized.resource("photo_effects_wheel_hint")))
        .accessibilityAddTraits(.isButton)
        .onChange(of: selected) { value in sync(value: value) }
        .onChange(of: gestureConfiguration) { _ in
            // Android restarts pointerInput for these keys. Invalidate queued
            // callbacks as well as replacing the recognizer, including ABA changes.
            longPressFeedback.end()
            dragSession.update(configuration: gestureConfiguration)
            dragging = false
            position = CGFloat(selectedIndex)
        }
        .onChange(of: pressing) { active in
            if !active { longPressFeedback.end() }
        }
        .onChange(of: dragging) { active in
            if active { longPressFeedback.cancel() }
        }
        .onDisappear { longPressFeedback.end() }
        .onPreferenceChange(DetentWheelContentAnchorPreferenceKey.self) { frame in
            guard frame != .zero else { return }
            onContentAnchorChange?(frame)
        }
        .onChange(of: gestureActive) { active in
            // GestureState resets automatically when SwiftUI cancels a drag
            // (for example when a parent ScrollView takes ownership). A normal
            // release clears `dragging` in onEnded first, so only cancellation
            // reaches this rollback path.
            if !active, dragging {
                dragSession.invalidate()
                dragging = false
                position = CGFloat(selectedIndex)
            }
        }
    }

    @ViewBuilder private func wheelRows(center: CGFloat) -> some View {
        // Android ReleaseCommitWheel renders accepted identity while idle.
        // A rejected/deferred request must never become the displayed value.
        // Configuration changes also hide stale preview before onChange runs.
        let previewing = dragging && dragSession.configuration == gestureConfiguration
        let displayPosition = previewing ? position : CGFloat(selectedIndex)
        let centerIndex = min(max(Int(displayPosition.rounded()), 0), options.count - 1)
        // A shorter list can render before onChange rolls back the old preview.
        let boundedPosition = min(max(displayPosition, 0), CGFloat(options.count - 1))
        let indices = previewing ? Array(max(0, Int(floor(boundedPosition)) - 1)...min(options.count - 1, Int(ceil(boundedPosition)) + 1)) : [centerIndex]
        ForEach(indices, id: \.self) { index in
            let fontSize = optionFontSizeFor?(options[index]) ?? optionFontSize
            let distance = abs(CGFloat(index) - displayPosition); let active = distance < 0.5
            let baseColor = emphasized && active ? accent : (optionTextColor ?? ZTransferColors.primaryText)
            let color = baseColor
                .opacity(active ? 1 : (dark ? 0.50 : 0.38))
            HStack(spacing: 4) {
                if favoriteOption(options[index]) { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle((favoriteIconColor ?? accent).opacity(active ? 1 : 0.38)) }
                if let centerIcon { centerIcon(color) }
                Text(AppLocalized.text(optionLabel(options[index])))
                    .font(.system(size: active ? fontSize : max(optionFontSizeFor == nil ? 12 : 10, fontSize - 2), weight: optionFontWeight ?? (active ? .semibold : .regular)))
                    .lineLimit(optionMaxLines)
                    .fixedSize(horizontal: false, vertical: optionMaxLines > 1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(color)
                    .background {
                        if active, let contentAnchorSpace {
                            GeometryReader { geometry in
                                Color.clear
                                    .allowsHitTesting(false)
                                    .preference(
                                        key: DetentWheelContentAnchorPreferenceKey.self,
                                        value: geometry.frame(in: .named(contentAnchorSpace))
                                    )
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity).frame(height: rowHeight)
            // ZStack already centers each row. Only move neighboring rows by
            // their detent delta; adding a second center offset puts the value
            // at the bottom of the wheel.
            .offset(y: (CGFloat(index) - displayPosition) * rowHeight)
        }
    }

    private var dragGesture: some Gesture {
        let revision = dragSession.revision
        return DragGesture(minimumDistance: canDrag ? 2 : .infinity)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard revision == dragSession.revision, enabled, !readOnly, canDrag else { return }
                if !dragging {
                    guard dragSession.begin(revision: revision, selectedIndex: selectedIndex) else { return }
                    dragging = true
                }
                guard let next = dragSession.preview(revision: revision, translation: value.translation.height) else { return }
                if Int(next.rounded()) != Int(position.rounded()) { emitDetent() }; position = next
            }
            .onEnded { value in
                guard revision == dragSession.revision else { return }
                guard dragging, enabled, !readOnly, canDrag else {
                    dragSession.invalidate()
                    dragging = false
                    position = CGFloat(selectedIndex)
                    return
                }
                guard let target = dragSession.release(revision: revision, translation: value.translation.height) else { return }
                dragging = false
                withAnimation(ZTransferMotion.standard) { position = CGFloat(target) }
                if target != selectedIndex { onCommit(options[target]) }
            }
    }

    private func activate() {
        guard enabled, !readOnly else { return }
        if let onActivated { onActivated(); return }
        let target = (selectedIndex + 1) % options.count
        guard target != selectedIndex else { return }
        emitDetent()
        // Android's click path only requests a change. A picker or a missing
        // favorite asset may defer/reject it; keep displaying the accepted
        // selection until onChange(selected) animates the committed value.
        onCommit(options[target])
    }

    private var clickGesture: AnyGesture<Void> {
        guard onLongClick != nil else {
            return AnyGesture(TapGesture().onEnded { activate() })
        }
        // One touch sequence chooses exactly one action. A completed long
        // press consumes its own release; the next touch has a fresh choice.
        // Unlike a timer-based tap guard, cancellation leaves no delayed state.
        return AnyGesture(
            LongPressGesture(minimumDuration: Double(longPressDurationMilliseconds) / 1_000)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    guard enabled, !readOnly else { return }
                    switch result {
                    case .first(let completed):
                        if completed { longPressFeedback.trigger { onLongClick?() } }
                    case .second:
                        activate()
                    }
                }
                .map { _ in () }
        )
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressing) { _, active, _ in
                if (prominentPressFeedback || onLongClick != nil) && enabled && !readOnly { active = true }
            }
            .onChanged { _ in
                guard onLongClick != nil, enabled, !readOnly, !dragging else { return }
                longPressFeedback.begin(durationMilliseconds: longPressDurationMilliseconds)
            }
            .onEnded { _ in longPressFeedback.end() }
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
        // A custom callback replaces the default, never adds a second tick.
        if let onDetent { onDetent() }
        else { ZTransferHaptics.shared.tick() }
    }
}

/// ReleaseCommitWheel.WheelDragHint: two 6×20pt decorative chevrons.
private struct DetentWheelDragHint: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0.5, y: 3))
            path.addLine(to: CGPoint(x: rect.midX, y: 0.5))
            path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: 3))
            path.move(to: CGPoint(x: 0.5, y: rect.maxY - 3))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 0.5))
            path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 3))
        }
    }
}

private struct DetentWheelContentAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Android pointerInput cancellation invalidates the whole drag, even if its
/// configuration later returns to the original value. Selected-value changes
/// alone keep the active start index, matching rememberUpdatedState on Android.
struct DetentWheelConfiguration<Option: Hashable>: Hashable {
    let options: [Option]
    let rowHeight: CGFloat
    let enabled: Bool
    let readOnly: Bool
    private let optionsHash: Int

    init(options: [Option], rowHeight: CGFloat, enabled: Bool, readOnly: Bool) {
        self.options = options; self.rowHeight = rowHeight
        self.enabled = enabled; self.readOnly = readOnly
        optionsHash = options.hashValue
    }

    // SwiftUI asks for this gesture identity while the wheel is moving. Hash
    // the option list once with the incoming configuration, not on every drag
    // frame. Full equality still protects against hash collisions and reorder.
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(optionsHash); hasher.combine(rowHeight)
        hasher.combine(enabled); hasher.combine(readOnly)
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.optionsHash == rhs.optionsHash && lhs.rowHeight == rhs.rowHeight
            && lhs.enabled == rhs.enabled && lhs.readOnly == rhs.readOnly && lhs.options == rhs.options
    }

    var canDrag: Bool { enabled && !readOnly && options.count > 3 }
}

struct DetentWheelDragSession<Option: Hashable> {
    private(set) var configuration: DetentWheelConfiguration<Option>

    mutating func update(configuration: DetentWheelConfiguration<Option>) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        invalidate()
    }

    private(set) var revision: UInt64 = 0
    private var startIndex: Int?

    mutating func invalidate() {
        revision &+= 1
        startIndex = nil
    }

    mutating func begin(revision: UInt64, selectedIndex: Int) -> Bool {
        guard revision == self.revision, configuration.canDrag else { return false }
        startIndex = selectedIndex
        return true
    }

    func preview(revision: UInt64, translation: CGFloat) -> CGFloat? {
        guard revision == self.revision, let startIndex, configuration.canDrag else { return nil }
        return min(max(CGFloat(startIndex) - translation / max(configuration.rowHeight, 1), 0), CGFloat(configuration.options.count - 1))
    }

    mutating func release(revision: UInt64, translation: CGFloat) -> Int? {
        guard let position = preview(revision: revision, translation: translation) else { return nil }
        startIndex = nil
        return Int(position.rounded())
    }
}

/// Hit-test-transparent markers let both native paging and the SwiftUI fallback
/// respect Android ReleaseCommitWheel's consumed vertical drags. No recognizer
/// is added, and short-list click controls keep their existing scroll behavior.
struct WheelDragRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> WheelDragRegionView { WheelDragRegionView() }
    func updateUIView(_ uiView: WheelDragRegionView, context: Context) {}
}

final class WheelDragRegionView: UIView {
    private static let regions = NSHashTable<WheelDragRegionView>.weakObjects()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        Self.regions.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func contains(_ point: CGPoint, in source: UIView? = nil) -> Bool {
        regions.allObjects.contains { region in
            guard let window = region.window,
                  source == nil || source?.window === window else { return false }
            var ancestor: UIView? = region
            while let view = ancestor {
                if view.isHidden || view.alpha <= 0.01 { return false }
                ancestor = view.superview
            }
            return region.bounds.contains(region.convert(point, from: source ?? window))
        }
    }
}
