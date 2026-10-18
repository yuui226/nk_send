import Foundation
import Combine

/// Android RemoteToolPreferences.kt declaration order is the fallback order for
/// newly introduced tools; never derive it from localized titles.
enum RemoteTool: String, CaseIterable, Identifiable, Sendable {
    case hd, fps, audio, histogram, grid, exposure, desqueeze, level
    case whiteBalance = "white_balance"
    case focusArea = "focus_area"
    case waveform, focusMode = "focus_mode", focusFrame = "focus_frame", lut, pictureControl = "picture_control", meter, lock
    case computerControl = "computer_control", rotate

    var id: String { rawValue }
    var fixed: Bool { self == .rotate || self == .lock }
    static let pinned: [RemoteTool] = [.lock, .rotate]
    func available(movie: Bool) -> Bool { self != .audio || movie }
    static var regular: [RemoteTool] { allCases.filter { !$0.fixed } }
    var titleKey: String {
        switch self {
        case .whiteBalance: "remote_tool_wb"
        default: "remote_tool_\(rawValue)"
        }
    }
    static func ordered(ids: [String]) -> [RemoteTool] {
        var seen = Set<RemoteTool>()
        return (ids.compactMap(RemoteTool.init(rawValue:)).filter { !$0.fixed } + regular)
            .filter { seen.insert($0).inserted }
    }
}

/// Photo/movie stores are independent; orientation does not create a third
/// layout. All mutations persist immediately, including detaching the lock slot.
@MainActor
final class RemoteToolLayout: ObservableObject {
    let available: [RemoteTool]
    @Published private(set) var order: [RemoteTool]
    @Published private(set) var hidden: Set<String>
    private let defaults: UserDefaults
    private let onHide: (RemoteTool) -> Void
    private let orderKey: String
    private let hiddenKey: String

    init(defaults: UserDefaults, movie: Bool, onHide: @escaping (RemoteTool) -> Void) {
        self.defaults = defaults
        self.onHide = onHide
        let mode = movie ? "movie" : "photo"
        orderKey = "remote_tool_order_\(mode)"
        hiddenKey = "remote_hidden_tools_\(mode)"
        available = RemoteTool.regular.filter { $0.available(movie: movie) }
        order = RemoteTool.ordered(ids: (defaults.string(forKey: orderKey) ?? "").components(separatedBy: ","))
            .filter { $0.available(movie: movie) }
        let availableIDs = Set(RemoteTool.regular.filter { $0.available(movie: movie) }.map(\.id))
        hidden = Set((defaults.stringArray(forKey: hiddenKey) ?? []).filter { availableIDs.contains($0) })
        let placementKey = "remote_picture_control_placement_v1_\(mode)"
        if !defaults.bool(forKey: placementKey) {
            hidden.remove(RemoteTool.pictureControl.id)
            let others = order.filter { $0 != .pictureControl }
            let preceding = others.indices.filter { !hidden.contains(others[$0].id) }.prefix(5)
            order = others
            order.insert(.pictureControl, at: preceding.last.map { $0 + 1 } ?? 0)
            defaults.set(order.map(\.id).joined(separator: ","), forKey: orderKey)
            defaults.set(hidden.sorted(), forKey: hiddenKey)
            defaults.set(true, forKey: placementKey)
        }
    }

    func visible(_ tool: RemoteTool) -> Bool {
        tool.fixed || (available.contains(tool) && !hidden.contains(tool.id))
    }
    var shownTools: [RemoteTool] { order.filter(visible) }
    var hiddenTools: [RemoteTool] { order.filter { !visible($0) } }

    func move(_ tool: RemoteTool, to index: Int) {
        guard !tool.fixed, visible(tool) else { return }
        var shown = shownTools
        guard let source = shown.firstIndex(of: tool) else { return }
        shown.remove(at: source)
        shown.insert(tool, at: min(max(index, 0), shown.count))
        order = shown + hiddenTools
        save()
    }

    func setVisible(_ tool: RemoteTool, _ isVisible: Bool) {
        guard !tool.fixed, available.contains(tool) else { return }
        // Reapplying a hidden layout must stop active features too, even when
        // its stored visibility already equals false.
        if !isVisible { onHide(tool) }
        guard visible(tool) != isVisible else { return }
        let others = order.filter { $0 != tool }
        if isVisible { hidden.remove(tool.id) } else { hidden.insert(tool.id) }
        let shown = others.filter(visible)
        let hiddenTail = others.filter { !visible($0) }
        order = isVisible ? shown + [tool] + hiddenTail : shown + hiddenTail + [tool]
        save()
    }

    private func save() {
        defaults.set(order.map(\.id).joined(separator: ","), forKey: orderKey)
        defaults.set(hidden.sorted(), forKey: hiddenKey)
    }
}
