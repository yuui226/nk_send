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

/// Android SettingsScreen.detectTapGestures / ZoomablePreviewViewport share
/// one owner for tap, double tap and 500ms comparison. A completed hold must
/// consume the release; composing a sequenced SwiftUI drag with exclusive taps
/// can swallow short taps or fall back to a tap after a 600ms hold.
struct PhotoEffectsImageInput: UIViewRepresentable {
    @Binding var comparing: Bool
    var enabled = true
    let comparisonEnabled: Bool
    let onTap: (CGPoint) -> Void
    var onDoubleTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> InputView { InputView() }
    func updateUIView(_ view: InputView, context: Context) {
        view.onComparison = { comparing = $0 }
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        view.singleTap.isEnabled = enabled
        view.doubleTap.isEnabled = enabled && onDoubleTap != nil
        view.hold.isEnabled = enabled && comparisonEnabled
        if !view.hold.isEnabled { view.setComparing(false) }
    }
    static func dismantleUIView(_ view: InputView, coordinator: ()) { view.cancel() }

    // Android 8f64f803: only a confirmed comparison hold vibrates; press/pan/pinch remain silent.
    final class SingleFingerHold: UILongPressGestureRecognizer {
        private var contacts: Set<UITouch> = []
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            contacts.formUnion(touches)
            guard contacts.count == 1 else {
                state = state == .possible ? .failed : .cancelled
                return
            }
            super.touchesBegan(touches, with: event)
        }
        override func reset() { super.reset(); contacts.removeAll() }
    }

    final class InputView: UIView, UIGestureRecognizerDelegate {
        let singleTap = UITapGestureRecognizer()
        let doubleTap = UITapGestureRecognizer()
        let hold = SingleFingerHold()
        var onComparison: ((Bool) -> Void)?
        var onTap: ((CGPoint) -> Void)?
        var onDoubleTap: ((CGPoint) -> Void)?
        var haptics = ZTransferHaptics.shared
        private(set) var comparing = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            doubleTap.numberOfTapsRequired = 2
            hold.minimumPressDuration = 0.5
            hold.allowableMovement = 10
            singleTap.require(toFail: doubleTap)
            singleTap.require(toFail: hold)
            doubleTap.require(toFail: hold)
            for recognizer in [singleTap, doubleTap, hold] {
                recognizer.delegate = self
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                addGestureRecognizer(recognizer)
            }
            singleTap.addTarget(self, action: #selector(tapped(_:)))
            doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
            hold.addTarget(self, action: #selector(held(_:)))
            NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancel() }
        }
        func setComparing(_ active: Bool) {
            guard comparing != active else { return }
            comparing = active
            onComparison?(active)
            if active { haptics.play(.holdConfirmed) }
        }
        @objc func cancel() {
            for recognizer in [singleTap, doubleTap, hold] {
                let enabled = recognizer.isEnabled
                recognizer.isEnabled = false
                recognizer.isEnabled = enabled
            }
            setComparing(false)
        }
        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { onTap?(recognizer.location(in: window)) }
        }
        @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { onDoubleTap?(recognizer.location(in: window)) }
        }
        @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { setComparing(true) }
            else if recognizer.state != .changed { setComparing(false) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Ancestor paging/pan and the window pinch observer keep receiving
            // touches. Only our three image actions are mutually exclusive.
            other.view !== self
        }
    }
}

struct PhotoEffectsExpandedImageSurface: View {
    let image: UIImage
    let comparison: UIImage?
    @ObservedObject var interaction: PhotoEffectsExpandedInteraction
    let closing: Bool
    let onClose: () -> Void
    @State private var comparing = false
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
                    .overlay { PhotoEffectsImageInput(comparing: $comparing, enabled: !closing,
                        comparisonEnabled: comparison != nil && !closing && !interaction.magnifying,
                        onTap: { _ in
                            guard !closing, !interaction.magnifying else { return }
                            if interaction.transform.scale <= 1.01 { onClose() }
                        }, onDoubleTap: { point in
                            guard !closing, !interaction.magnifying else { return }
                            let frame = proxy.frame(in: .global)
                            interaction.doubleTap(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                                imageSize: image.size, viewport: proxy.size)
                        }) }
                    .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged { value in
                            guard !closing else { return }
                            interaction.drag(translation: value.translation, imageSize: image.size, viewport: proxy.size)
                        }.onEnded { _ in interaction.endDrag() })
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
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--gesture-audit-ui-test") {
                Text("zoom=\(String(format: "%.2f", interaction.transform.scale));offset=\(Int(interaction.transform.offset.width)),\(Int(interaction.transform.offset.height));comparison=\(comparing ? 1 : 0)")
                    .font(.system(size: 8)).allowsHitTesting(false)
                    .accessibilityIdentifier("expanded-gesture-state")
            }
        }
        #endif
    }
}
