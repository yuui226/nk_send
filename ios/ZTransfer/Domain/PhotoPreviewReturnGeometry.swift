import Foundation
import CoreGraphics

/// Android FileListScreen returns an offscreen preview target 88dp below the
/// grid's visible top. ScrollViewReader aligns matching unit points of the item
/// and viewport, so solve y * (viewportHeight - itemHeight) = 88.
func photoPreviewReturnAnchor(viewportHeight: CGFloat, itemHeight: CGFloat) -> CGFloat {
    guard viewportHeight.isFinite, itemHeight.isFinite, itemHeight > 0,
          viewportHeight > itemHeight else { return 0 }
    return min(1, 88 / (viewportHeight - itemHeight))
}
