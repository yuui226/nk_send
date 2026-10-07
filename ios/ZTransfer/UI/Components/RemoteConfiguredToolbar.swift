import SwiftUI

/// Observes the active photo/movie layout directly: changing a layout must
/// redraw even when no feature preference changed (for example moving RECORD).
struct RemoteFixedToolControl: Identifiable {
    let id: String
    let view: AnyView
}

struct RemoteConfiguredToolbar<Leading: View>: View {
    @ObservedObject var layout: RemoteToolLayout
    let editing: Bool
    let isActive: Bool
    let controls: [RemoteTool: AnyView]
    let leading: Leading
    let trailing: [RemoteFixedToolControl]
    let pinnedEndCount: Int
    let fixedRecorder: Bool
    let applyHidden: ([RemoteTool]) -> Void

    @StateObject private var drag = RemoteToolDragState()
    @StateObject private var motion = RemoteToolEditorMotion()
    @Environment(\.displayScale) private var displayScale
    @State private var mounted = false
    @State private var fixedSlots: [String: CGRect] = [:]
    @State private var coordinateID = UUID()
    @State private var previousTranslation = CGSize.zero
    @GestureState private var gestureActive = false

    private var sequence: [RemoteTool] {
        editing ? layout.shownTools + layout.hiddenTools : layout.presentedTools(fixedRecorder: fixedRecorder)
    }

    var body: some View {
        RemoteAdaptiveToolLayout(displayScale: displayScale, horizontalSpacing: 6, verticalSpacing: 4,
                                 pinnedEndCount: pinnedEndCount,
                                 secondRowFirst: layout.lockStartsSecondRow ? .lock : nil) {
            leading
            ForEach(sequence) { tool in
                if let control = controls[tool] {
                    ZStack {
                        control
                            .environment(\.remoteToolIconOpacity, Double(motion.states[tool]?.iconOpacity.value ?? (layout.visible(tool) ? 1 : 0.38)))
                            .scaleEffect(CGFloat(motion.states[tool]?.lift.value ?? 1))
                            .rotationEffect(.degrees(Double(motion.states[tool]?.angle ?? 0)))
                            .offset(offset(for: tool))
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: RemoteToolSlotPreference.self,
                                                   value: [tool: proxy.frame(in: .named(coordinateID))])
                        }
                    }
                    .layoutValue(key: RemoteToolLayoutID.self, value: tool)
                    .zIndex(drag.dragging == tool ? 1 : 0)
                    .accessibilityIdentifier("remote-tool-\(tool.id)")
                }
            }
            ForEach(trailing) { control in
                ZStack { control.view.offset(fixedOffset(for: control.id)) }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: RemoteFixedToolSlotPreference.self,
                                value: [control.id: proxy.frame(in: .named(coordinateID))])
                        }
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: RemoteToolHeightPreference.self, value: proxy.size.height)
            }
        }
        .frame(height: editing ? motion.contentHeight.height : nil, alignment: .topLeading)
        .modifier(RemoteToolEditingClip(enabled: editing))
        .onPreferenceChange(RemoteToolHeightPreference.self) {
            motion.measureHeight($0, editing: editing, scale: displayScale)
        }
        .overlay(alignment: .bottomLeading) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--remote-tools-ui-test") {
                Text("order=\(layout.shownTools.map(\.id).joined(separator: ","));hidden=\(layout.hidden.sorted().joined(separator: ","))")
                    .font(.system(size: 1)).allowsHitTesting(false)
                    .accessibilityIdentifier("remote-tool-state")
            }
            #endif
        }
        .coordinateSpace(name: coordinateID)
        .onPreferenceChange(RemoteToolSlotPreference.self) { slots in
            drag.slots = slots
            drag.visualPositions = slots.reduce(into: [:]) { positions, entry in
                let tool = entry.key
                positions[tool] = { [weak motion] in motion?.position(tool) ?? entry.value.origin }
            }
            updateMotion()
        }
        .onPreferenceChange(RemoteFixedToolSlotPreference.self) { slots in
            fixedSlots = slots
            updateMotion()
        }
        .onChange(of: drag.topLeft) { _ in updateMotion() }
        .onChange(of: drag.dragging) { _ in updateMotion() }
        .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named(coordinateID))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard editing, isActive else { return }
                if drag.dragging == nil {
                    _ = drag.begin(at: value.startLocation, delta: value.translation, layout: layout)
                } else {
                    drag.moveBy(CGSize(width: value.translation.width - previousTranslation.width,
                                       height: value.translation.height - previousTranslation.height), layout: layout)
                }
                previousTranslation = value.translation
            }
            .onEnded { _ in endDrag() }, including: editing && isActive ? .all : .none)
        .onChange(of: gestureActive) { if !$0 { endDrag() } }
        .onChange(of: editing) { _ in endDrag(); updateMotion() }
        .onChange(of: isActive) { if !$0 { endDrag() } }
        .onDisappear { mounted = false; endDrag(); motion.stop() }
        .onAppear { mounted = true; applyLayout(); updateMotion() }
        .onChange(of: layout.hidden) { _ in applyLayout(); updateMotion() }
        .onChange(of: fixedRecorder) { _ in applyLayout() }
        .onChange(of: isActive) { _ in applyLayout() }
    }

    private func offset(for tool: RemoteTool) -> CGSize {
        guard editing, let slot = drag.slots[tool], let point = motion.position(tool) else { return .zero }
        return CGSize(width: point.x - slot.minX, height: point.y - slot.minY)
    }

    private func fixedOffset(for id: String) -> CGSize {
        guard editing, let slot = fixedSlots[id], let point = motion.fixedPosition(id) else { return .zero }
        return CGSize(width: point.x - slot.minX, height: point.y - slot.minY)
    }

    private func updateMotion() {
        guard mounted else { return }
        motion.configure(slots: drag.slots, fixedSlots: fixedSlots, editing: editing,
                         visible: Set(layout.shownTools), dragging: drag.dragging,
                         topLeft: drag.topLeft, scale: displayScale)
    }

    private func endDrag() {
        drag.end()
        previousTranslation = .zero
    }

    private func applyLayout() {
        guard isActive else { return }
        // Android ApplyRemoteToolLayout preserves an active landscape recording
        // when the mode's portrait recording entry is hidden.
        applyHidden(layout.hiddenTools.filter { !fixedRecorder || $0 != .record })
    }
}

private struct RemoteToolSlotPreference: PreferenceKey {
    static let defaultValue: [RemoteTool: CGRect] = [:]
    static func reduce(value: inout [RemoteTool: CGRect], nextValue: () -> [RemoteTool: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Observing visibility here also updates action-only entries such as RECORD,
/// whose hide/restore does not mutate a published feature preference.
struct RemoteToolVisibilityContent<Content: View>: View {
    @ObservedObject var layout: RemoteToolLayout
    let tool: RemoteTool
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(layout.visible(tool)) }
}

private struct RemoteToolHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct RemoteToolEditingClip: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.clipped() } else { content }
    }
}

private struct RemoteFixedToolSlotPreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
