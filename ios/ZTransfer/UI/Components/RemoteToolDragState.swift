import Foundation
import Combine

/// RemoteToolBar.ToolDragState. All coordinates are toolbar-local, so the host
/// screen's internal rotation does not enter hit testing or reorder math.
@MainActor
final class RemoteToolDragState: ObservableObject {
    var slots: [RemoteTool: CGRect] = [:]
    var visualPositions: [RemoteTool: () -> CGPoint] = [:]
    @Published private(set) var dragging: RemoteTool?
    @Published private(set) var topLeft = CGPoint.zero

    func visualBounds(_ tool: RemoteTool) -> CGRect? {
        guard let slot = slots[tool] else { return nil }
        return CGRect(origin: visualPositions[tool]?() ?? slot.origin, size: slot.size)
    }

    /// Called after touch slop has been consumed. The UI supplies the original
    /// down location and full accumulated movement, not only the excess slop.
    @discardableResult
    func begin(at down: CGPoint, delta: CGSize, layout: RemoteToolLayout) -> Bool {
        guard let tool = layout.shownTools.first(where: {
            visualBounds($0).map { Self.contains($0, down) } ?? false
        }), let bounds = visualBounds(tool) else { return false }
        dragging = tool
        topLeft = bounds.origin
        moveBy(delta, layout: layout)
        return true
    }

    func moveBy(_ delta: CGSize, layout: RemoteToolLayout) {
        guard let tool = dragging else { return }
        topLeft.x += delta.width
        topLeft.y += delta.height
        guard let size = slots[tool]?.size else { return }
        let center = CGPoint(x: topLeft.x + size.width / 2, y: topLeft.y + size.height / 2)
        // Destination rectangles, deliberately not the animated neighbors.
        guard let target = layout.shownTools.first(where: {
            $0 != tool && slots[$0].map { Self.contains($0, center) } == true
        }), let targetIndex = layout.shownTools.firstIndex(of: target) else { return }
        let displayed = layout.shownTools.enumerated().sorted { lhs, rhs in
            let left = slots[lhs.element]?.origin ?? CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
            let right = slots[rhs.element]?.origin ?? CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
            if left.y != right.y { return left.y < right.y }
            if left.x != right.x { return left.x < right.x }
            return lhs.offset < rhs.offset
        }.map(\.element)
        layout.move(tool, to: targetIndex, displayedOrder: displayed)
    }

    func end() { dragging = nil }

    func remove(_ tool: RemoteTool) {
        slots.removeValue(forKey: tool)
        visualPositions.removeValue(forKey: tool)
        if dragging == tool { end() }
    }

    // Compose Rect.contains includes left/top and excludes right/bottom.
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
    }
}
