import Foundation
import CoreGraphics

enum PhotoListCellID: Hashable {
    case photo(UInt32)
    case burst(String)
    case burstEnqueue(String)
}

func visiblePhotoListCellBounds(_ id: PhotoListCellID, bounds: [PhotoListCellID: CGRect],
                                viewport: CGRect) -> CGRect? {
    guard let frame = bounds[id], !frame.isEmpty, !frame.isInfinite, !frame.isNull,
          frame.intersects(viewport) else { return nil }
    return frame
}

func photoPreviewAnchorBounds(_ id: PhotoListCellID, bounds: [PhotoListCellID: CGRect],
                              viewport: CGRect) -> PhotoPreviewAnchorBounds? {
    guard let image = bounds[id] else { return nil }
    return PhotoPreviewAnchorBounds.clipped(image: image, to: viewport)
}
