import SwiftUI
import UIKit

struct PhotoEffectsExpandedTransform: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var rotationDegrees: Double = 0
}

/// PhotoPreview.kt / ZoomablePreviewViewport: Float tween(240) zoom,
/// tween(220) rotation, and gestures that cancel zoom at its displayed value.
/// No image decoding or allocation belongs to this motion state.
struct PhotoEffectsExpandedMotion {
    private(set) var transform = PhotoEffectsExpandedTransform()
    private(set) var magnifying = false
    private var rotation = ZTransferScalarAnimation(value: 0)
    private var zoom = ZTransferScalarAnimation(value: 0)
    private var zoomFrom = PhotoEffectsExpandedTransform()
    private var zoomTargetScale: CGFloat = 1
    private var zoomTargetOffset: CGSize = .zero
    private var dragging = false
    private var dragStartOffset: CGSize = .zero
    private var dragStartTranslation: CGSize = .zero
    private var lastDragTranslation: CGSize = .zero

    var isRunning: Bool { rotation.isRunning || zoom.isRunning }
    var targetRotation: Double { Double(rotation.target) }

    mutating func doubleTap(at point: CGPoint, imageSize: CGSize, viewport: CGSize) {
        guard !magnifying else { return }
        cancelZoom()
        zoomFrom = transform
        zoomTargetScale = transform.scale > 1.01 ? 1 : 2.5
        zoomTargetOffset = zoomTargetScale == 1 ? .zero : photoPreviewDoubleTapOffset(
            location: point, scale: zoomTargetScale, imageSize: imageSize,
            viewportSize: viewport, rotationDegrees: targetRotation)
        zoom.retarget(1, using: .tween(milliseconds: 240))
    }

    mutating func rotate() {
        cancelZoom()
        transform.scale = 1
        transform.offset = .zero
        rotation.retarget(rotation.target - 90, using: .tween(milliseconds: 220))
        rebaseDrag()
    }

    mutating func drag(translation: CGSize, imageSize: CGSize, viewport: CGSize) {
        lastDragTranslation = translation
        if !dragging {
            dragging = true
            cancelZoom()
            dragStartOffset = transform.offset
            dragStartTranslation = .zero
        }
        guard !magnifying else { rebaseDrag(); return }
        guard transform.scale > 1.01 else { return }
        let proposed = CGSize(width: dragStartOffset.width + translation.width - dragStartTranslation.width,
                              height: dragStartOffset.height + translation.height - dragStartTranslation.height)
        transform.offset = photoPreviewClampedOffset(proposed, scale: transform.scale,
            imageSize: imageSize, viewportSize: viewport, rotationDegrees: targetRotation)
    }

    mutating func endDrag() {
        dragging = false
        lastDragTranslation = .zero
        rebaseDrag()
    }

    mutating func setMagnifying(_ active: Bool) {
        guard active != magnifying else { return }
        magnifying = active
        if active { cancelZoom() }
        else if transform.scale <= 1.01 {
            transform.scale = 1; transform.offset = .zero
        }
        rebaseDrag()
    }

    mutating func pinch(factor: CGFloat, centroid: CGPoint, pan: CGSize,
                        imageSize: CGSize, viewport: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        cancelZoom()
        let next = min(max(transform.scale * factor, 1), photoPreviewMaximumZoom(
            imageSize: imageSize, viewportSize: viewport, rotationDegrees: targetRotation))
        let placement = photoPreviewPlacement(imageSize: imageSize, viewportSize: viewport, rotationDegrees: targetRotation)
        let proposed = previewPinchOffset(offset: transform.offset,
            centroidFromCenter: CGPoint(x: centroid.x - placement.center.x, y: centroid.y - placement.center.y),
            factor: next / max(transform.scale, 0.01), pan: pan)
        transform.scale = next
        transform.offset = photoPreviewClampedOffset(proposed, scale: next,
            imageSize: imageSize, viewportSize: viewport, rotationDegrees: targetRotation)
    }

    mutating func advance(_ nanos: Int64) {
        if rotation.isRunning {
            rotation.advance(frameNanos: nanos)
            transform.rotationDegrees = Double(rotation.value)
        }
        if zoom.isRunning {
            zoom.advance(frameNanos: nanos)
            let progress = CGFloat(zoom.value)
            transform.scale = zoomFrom.scale + (zoomTargetScale - zoomFrom.scale) * progress
            transform.offset = CGSize(
                width: zoomFrom.offset.width + (zoomTargetOffset.width - zoomFrom.offset.width) * progress,
                height: zoomFrom.offset.height + (zoomTargetOffset.height - zoomFrom.offset.height) * progress)
        }
    }

    mutating func cancelZoom() { zoom.reset(to: 0) }
    private mutating func rebaseDrag() {
        dragStartOffset = transform.offset
        dragStartTranslation = lastDragTranslation
    }
}

/// Retained by the overlay without observing it; only the image surface reads
/// display frames. All channels publish together and settle without a timer.
@MainActor
final class PhotoEffectsExpandedInteraction: ObservableObject {
    private struct Display: Equatable {
        var transform = PhotoEffectsExpandedTransform()
        var magnifying = false
    }
    @Published private var display = Display()
    private var motion = PhotoEffectsExpandedMotion()
    private var link: CADisplayLink?
    private var active = false
    var transform: PhotoEffectsExpandedTransform { display.transform }
    var magnifying: Bool { display.magnifying }
    var isRunning: Bool { motion.isRunning }

    func setActive(_ active: Bool) {
        self.active = active
        if active { schedule() }
        else { stop(); motion.cancelZoom(); motion.setMagnifying(false); motion.endDrag(); publish() }
    }
    func doubleTap(at point: CGPoint, imageSize: CGSize, viewport: CGSize) {
        motion.doubleTap(at: point, imageSize: imageSize, viewport: viewport); publish(); schedule()
    }
    func rotate() { motion.rotate(); publish(); schedule() }
    func drag(translation: CGSize, imageSize: CGSize, viewport: CGSize) {
        motion.drag(translation: translation, imageSize: imageSize, viewport: viewport); publish(); schedule()
    }
    func endDrag() { motion.endDrag() }
    func setMagnifying(_ active: Bool) { motion.setMagnifying(active); publish(); schedule() }
    func pinch(factor: CGFloat, centroid: CGPoint, pan: CGSize, imageSize: CGSize, viewport: CGSize) {
        motion.pinch(factor: factor, centroid: centroid, pan: pan, imageSize: imageSize, viewport: viewport)
        publish(); schedule()
    }
    private func publish() {
        let next = Display(transform: motion.transform, magnifying: motion.magnifying)
        if display != next { display = next }
    }
    private func schedule() {
        guard active, motion.isRunning else { stop(); return }
        guard link == nil else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    private func stop() { link?.invalidate(); link = nil }
    private func frame(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000)); publish()
        if !motion.isRunning { stop() }
    }
    @MainActor private final class FrameTarget: NSObject {
        weak var owner: PhotoEffectsExpandedInteraction?
        init(_ owner: PhotoEffectsExpandedInteraction) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(link)
        }
    }
}

/// SequenceGesture.first(true) means the press is still waiting for its 500ms
/// threshold. Only the second stage has completed the long press.
func photoEffectsComparisonRequested(_ phase: SequenceGesture<LongPressGesture, DragGesture>.Value) -> Bool {
    if case .second(true, _) = phase { return true }
    return false
}

struct PhotoEffectsExpandedImageSurface: View {
    let image: UIImage
    let comparison: UIImage?
    @ObservedObject var interaction: PhotoEffectsExpandedInteraction
    let closing: Bool
    let onClose: () -> Void
    @GestureState private var comparing = false
    @GestureState private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let transform = interaction.transform
            ZStack {
                Image(uiImage: comparing && !interaction.magnifying && !closing ? (comparison ?? image) : image)
                    .resizable().scaledToFit()
                    .rotationEffect(.degrees(transform.rotationDegrees))
                    .scaleEffect(transform.scale * photoPreviewPlacement(imageSize: image.size,
                        viewportSize: proxy.size, rotationDegrees: transform.rotationDegrees).scale)
                    .offset(transform.offset)
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged { value in
                            guard !closing else { return }
                            interaction.drag(translation: value.translation, imageSize: image.size, viewport: proxy.size)
                        }.onEnded { _ in interaction.endDrag() })
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 12))
                        .updating($comparing) { value, state, _ in
                            guard comparison != nil, !closing, !interaction.magnifying else { return }
                            state = photoEffectsComparisonRequested(value)
                        })
                    .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .global)
                        .exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: .global))
                        .onEnded { gesture in
                            guard !closing, !interaction.magnifying else { return }
                            switch gesture {
                            case .first(let tap):
                                let frame = proxy.frame(in: .global)
                                interaction.doubleTap(at: CGPoint(x: tap.location.x - frame.minX, y: tap.location.y - frame.minY),
                                    imageSize: image.size, viewport: proxy.size)
                            case .second:
                                if interaction.transform.scale <= 1.01 { onClose() }
                            }
                        })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                PreviewPinchObserver(enabled: !closing, onActive: interaction.setMagnifying, onChange: { factor, centroid, pan in
                    interaction.pinch(factor: factor, centroid: centroid, pan: pan, imageSize: image.size, viewport: proxy.size)
                })
            }
        }
        // Explicit display-frame values must not inherit the overlay's enter /
        // leave transaction and animate a second time.
        .transaction { $0.animation = nil }
        .onAppear { interaction.setActive(true) }
        .onDisappear { interaction.setActive(false) }
        // SwiftUI does not call onEnded for a cancelled drag; GestureState
        // resets in both cases, so a new touch cannot reuse its old translation.
        .onChange(of: dragging) { if !$0 { interaction.endDrag() } }
    }
}
