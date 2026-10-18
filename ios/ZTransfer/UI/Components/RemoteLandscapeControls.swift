import SwiftUI
import UIKit

/// Final Android LandscapeMonitorControls.kt layout. The caller retains all
/// camera actions and preferences; this component owns only transient Dock UI.
struct RemoteLandscapeControls: View {
    let layout: RemoteLandscapeLayout
    @ObservedObject var toolLayout: RemoteToolLayout
    let controls: [RemoteTool: AnyView]
    let onPanelChange: () -> Void
    let onTick: () -> Void
    let applyHidden: ([RemoteTool]) -> Void
    let rotate: AnyView
    let back: AnyView
    let disp: AnyView
    let shutter: AnyView
    let recorder: AnyView
    var review: AnyView = AnyView(EmptyView())
    let parameter: (Int, CGFloat) -> AnyView
    // Only the layer views subscribe to frame changes. Label measurement and
    // the header are not rebuilt on every display-link tick.
    @State private var motion = RemoteDockMotionDriver()
    @State private var dockOpen = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if layout.bottomControls {
                HStack(spacing: 8) {
                    parameters.frame(maxWidth: .infinity, maxHeight: .infinity)
                    captureCluster.frame(width: max(116, layout.shutterSize + 52))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 40)
            } else {
                VStack(spacing: 4) {
                    Color.clear.frame(height: 36)
                    parameters.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Color.clear.frame(height: layout.footerHeight + layout.captureLift)
                }
                captureCluster.frame(maxHeight: .infinity, alignment: .bottom)
            }
            layer(dock: true) {
                RemoteLandscapeDock(tools: toolLayout.shownTools.filter { $0 != .record } + RemoteTool.pinned, controls: controls, bottom: layout.bottomControls)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 40)
            HStack(spacing: 0) {
                Button {
                    onTick()
                    onPanelChange()
                    dockOpen.toggle()
                    motion.setOpen(dockOpen)
                } label: {
                    RemoteDockMark().stroke(dockOpen ? ZTransferColors.accentBlue : ZTransferColors.primaryText,
                                            lineWidth: 1.6)
                        .frame(width: 19, height: 19)
                        .frame(width: 42, height: 36)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22, active: dockOpen))
                .accessibilityLabel(AppLocalized.resource("remote_tool_dock"))
                .accessibilityIdentifier("remote-landscape-dock")
                .accessibilityValue(dockOpen ? "open" : "closed")
                Spacer(minLength: 0)
                layer(dock: false) { back }
            }
            .frame(height: 36)
        }
        .onAppear { onPanelChange(); applyLayout() }
        .onChange(of: layout) { _ in onPanelChange() }
        .onChange(of: toolLayout.hidden) { _ in applyLayout() }
        .onChange(of: ObjectIdentifier(toolLayout)) { _ in applyLayout() }
        .onDisappear { motion.stop() }
    }

    private func applyLayout() { applyHidden(toolLayout.hiddenTools.filter { $0 != .record }) }

    private var parameters: some View {
        layer(dock: false) {
            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: layout.columns == 1 ? 2 : (layout.bottomControls ? 4 : 6)) {
                        ForEach(0..<(4 / layout.columns), id: \.self) { row in
                            HStack(spacing: 6) {
                                ForEach(0..<layout.columns, id: \.self) { column in
                                    parameter(row * layout.columns + column, layout.parameterHeight)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .frame(minHeight: proxy.size.height)
                }
            }
        }
    }

    private var captureCluster: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 4) {
                layer(dock: false) { disp }.frame(width: 36, height: 36)
                layer(dock: false) { rotate }.frame(width: 36, height: 36)
                layer(dock: false) { review }.frame(width: 36, height: 36)
            }.padding(.leading, 4)
            layer(dock: false) { shutter }
                .frame(width: layout.shutterSize, height: layout.shutterSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: !layout.bottomControls && layout.columns == 2 ? .top : .topTrailing)
            layer(dock: false) { recorder }.frame(height: 36).padding(.leading, 44)
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.footerHeight + layout.captureLift)
    }

    private func layer<Content: View>(dock: Bool, @ViewBuilder content: () -> Content) -> some View {
        RemoteDockLayer(motion: motion, dock: dock, content: content())
    }
}

private struct RemoteDockLayer<Content: View>: View {
    @ObservedObject var motion: RemoteDockMotionDriver
    let dock: Bool
    let content: Content
    var body: some View {
        let visibility = motion.state.visibility(dock: dock)
        if visibility > 0 {
            content
                .opacity(Double(visibility))
                .offset(y: CGFloat(1 - visibility) * 4)
                .disabled(!motion.state.acceptsInput(dock: dock))
                // A disabled Button alone does not consume a touch. The outgoing
                // surface must not pass taps through to another camera action.
                .overlay {
                    if !motion.state.acceptsInput(dock: dock) {
                        Color.clear.contentShape(Rectangle()).onTapGesture {}
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                    }
                }
                .accessibilityHidden(!motion.state.acceptsInput(dock: dock))
        }
    }
}

private struct RemoteDockMark: Shape {
    func path(in rect: CGRect) -> Path {
        var result = Path()
        let inset: CGFloat = 0.8, gap: CGFloat = 3
        let tile = (rect.width - 1.6 - gap) / 2
        for row in 0..<2 { for column in 0..<2 {
            result.addRoundedRect(in: CGRect(x: inset + CGFloat(column) * (tile + gap),
                                             y: inset + CGFloat(row) * (tile + gap), width: tile, height: tile),
                                  cornerSize: CGSize(width: 1.5, height: 1.5))
        } }
        return result
    }
}

@MainActor final class RemoteDockMotionDriver: NSObject, ObservableObject {
    @Published private(set) var state = RemoteDockMotion()
    private var link: CADisplayLink?
    func setOpen(_ open: Bool) {
        if state.open != open { state.setOpen(open) }
        guard state.animation.isRunning, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { $0.frame($1) }
        link = next
        next.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ sender: CADisplayLink) {
        state.advance(Int64(sender.timestamp * 1_000_000_000))
        if !state.animation.isRunning { stop() }
    }
    func stop() { link?.invalidate(); link = nil }
}

/// All label measurements precede the reveal. English words stay intact and
/// CJK may wrap between characters; each row reserves its largest line count.
struct RemoteDockMeasurements: Equatable {
    let columns: Int
    let lines: [Int]
    let cellWidth: CGFloat
    @MainActor init(names: [String], width: CGFloat, bottom: Bool, scale: CGFloat = 1, minimumColumns: Int = 1) {
        let scale = max(1, scale)
        let width = max(0, (width * scale).rounded()), gap = (8 * scale).rounded()
        let words = names.flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "-" }) }
        let wordWidth = words.map { word -> CGFloat in
            guard word.unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }) else { return 0 }
            return ceil((String(word) as NSString).size(withAttributes: RemoteDockLabel.attributes).width * scale)
        }.max() ?? 0
        let minimum = max((56 * scale).rounded(), wordWidth)
        let maximum = bottom ? max(1, min(max(1, names.count), Int((width + gap) / (minimum + gap)))) : 3
        let count = (minimumColumns...max(minimumColumns, maximum)).reversed().first { count in
            let cell = max(1, floor((width - gap * CGFloat(count - 1)) / CGFloat(count)))
            return count == minimumColumns || (cell >= minimum && names.allSatisfy { RemoteDockLabel.lineCount($0, width: cell / scale) <= 2 })
        } ?? 1
        columns = count
        let resolvedWidth = max(1, floor((width - gap * CGFloat(count - 1)) / CGFloat(count))) / scale
        cellWidth = resolvedWidth
        lines = names.map { min(2, max(1, RemoteDockLabel.lineCount($0, width: resolvedWidth))) }
    }
    func rowLines(_ row: Int) -> Int { lines.dropFirst(row * columns).prefix(columns).max() ?? 1 }
}

private struct RemoteLandscapeDock: View {
    let tools: [RemoteTool]
    let controls: [RemoteTool: AnyView]
    let bottom: Bool
    @Environment(\.displayScale) private var scale
    var body: some View {
        GeometryReader { proxy in
            let measure = RemoteDockMeasurements(names: tools.map { AppLocalized.resource($0.titleKey) },
                                                  width: max(0, proxy.size.width - 8), bottom: bottom, scale: scale, minimumColumns: max(1, tools.filter(\.fixed).count))
            let rows = monitorToolRows(tools, columns: measure.columns)
            RemoteDockScrollView {
                VStack(spacing: 8) {
                    ForEach(0..<rows.count, id: \.self) { row in
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(0..<measure.columns, id: \.self) { column in
                                let tool = column < rows[row].count ? rows[row][column] : nil
                                Group {
                                    if let tool {
                                        controls[tool]
                                            .environment(\.remoteDockLabelLines, 2)
                                    } else { Color.clear }
                                }.frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }.padding(.horizontal, 4)
        }
    }
}

private struct RemoteDockLabelLinesKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var remoteDockLabelLines: Int {
        get { self[RemoteDockLabelLinesKey.self] }
        set { self[RemoteDockLabelLinesKey.self] = newValue }
    }
}

/// The icon keeps the real themed button and its press feedback. A separate
/// backing hit target gives the label and the surrounding cell the same action.
struct RemoteDockToolCell<Content: View>: View {
    @Environment(\.remoteDockLabelLines) private var lines
    let id: String
    let title: String
    let active: Bool
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        if lines > 0 {
            ZStack(alignment: .top) {
                Button(action: action) { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityHidden(true)
                VStack(spacing: 0) {
                    content()
                    Button(action: action) {
                        RemoteDockLabel(text: title, lines: lines, color: active ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                            .frame(height: CGFloat(lines) * 12)
                            .padding(.top, 4)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(title)
                        .accessibilityIdentifier("remote-dock-label-\(id)")
                }
            }
            .frame(height: 36 + 4 + CGFloat(lines) * 12)
            .disabled(!enabled)
        } else { content() }
    }
}

private struct RemoteDockLabel: UIViewRepresentable {
    let text: String
    let lines: Int
    let color: Color
    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 12
        paragraph.maximumLineHeight = 12
        return [.font: UIFont.systemFont(ofSize: 10, weight: .medium), .paragraphStyle: paragraph]
    }
    static func lineCount(_ text: String, width: CGFloat) -> Int {
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        return max(1, Int(ceil(bounds.height / 12)))
    }
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = NSAttributedString(string: text, attributes: Self.attributes)
        label.textColor = UIColor(color)
        label.numberOfLines = lines
        label.lineBreakMode = .byTruncatingTail
    }
}

private struct RemoteDockScrollBounds: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// DstOut edge fade from ScrollEdgeFade.kt: 16dp (at most a quarter of
/// the viewport), 150ms FastOutSlowIn, only at edges with more scroll content.
private struct RemoteDockScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Namespace private var scrollSpace
    @State private var bounds = CGRect.zero
    @State private var topFade: CGFloat = 0
    @State private var bottomFade: CGFloat = 0
    var body: some View {
        GeometryReader { proxy in
            let depth = min(16, proxy.size.height / 4)
            ScrollView(.vertical, showsIndicators: false) {
                content().background(GeometryReader { contentProxy in
                    Color.clear.preference(key: RemoteDockScrollBounds.self,
                        value: contentProxy.frame(in: .named(scrollSpace)))
                })
            }
            .coordinateSpace(name: scrollSpace)
            .onPreferenceChange(RemoteDockScrollBounds.self) { bounds = $0 }
            .onChange(of: bounds) { _ in updateFade(height: proxy.size.height) }
            .onChange(of: proxy.size.height) { updateFade(height: $0) }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(1 - topFade), .black], startPoint: .top, endPoint: .bottom).frame(height: depth)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(1 - bottomFade)], startPoint: .top, endPoint: .bottom).frame(height: depth)
                }
            }
        }
    }
    private func updateFade(height: CGFloat) {
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)) {
            topFade = bounds.minY < -0.5 ? 1 : 0
            bottomFade = bounds.maxY > height + 0.5 ? 1 : 0
        }
    }
}

func monitorToolRows(_ tools: [RemoteTool], columns: Int) -> [[RemoteTool?]] {
    guard !tools.isEmpty else { return [] }
    let pinned = RemoteTool.pinned.filter { tools.contains($0) }
    let regular = tools.filter { !$0.fixed }
    let count = max(1, columns, pinned.count), firstCapacity = count - pinned.count
    let first: [RemoteTool?] = Array(regular.prefix(firstCapacity)) +
        Array(repeating: nil, count: max(0, firstCapacity - regular.count)) + pinned
    let remaining = Array(regular.dropFirst(firstCapacity))
    return [first] + stride(from: 0, to: remaining.count, by: count).map { start in
        Array(remaining[start..<min(start + count, remaining.count)]).map(Optional.some)
    }
}
