import SwiftUI
import UIKit

/// One live SwiftUI hierarchy, laid out at its final size. During a transition
/// Core Animation bends a single capture in small, bounded horizontal bands.
/// This uses public iOS 16 APIs, without Metal shaders or duplicate view trees.
@MainActor
struct GeniePopupPanel<Content: View>: UIViewRepresentable {
    let content: Content
    let trigger: GeniePopupTrigger
    let targetProgress: CGFloat
    let anchorX: CGFloat
    let anchorWidth: CGFloat
    let anchorGap: CGFloat
    var opensAbove = false
    var usesFunnel = true
    var fitsContentWidth = false
    var fillsProposedSize = false
    var onSettled: ((CGFloat) -> Void)? = nil
    var onProgress: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> GeniePopupHostView {
        // SwiftUI calls updateUIView after creation; assigning the hosted
        // content here too would build the same hierarchy twice.
        GeniePopupHostView()
    }

    func updateUIView(_ view: GeniePopupHostView, context: Context) {
        view.host.rootView = AnyView(content.environment(\.self, context.environment))
        view.accessibilityIdentifier = "popup-panel-\(trigger.rawValue)"
        view.onSettled = onSettled
        view.onProgress = onProgress
        view.configure(target: targetProgress, anchorX: anchorX,
                       anchorWidth: anchorWidth, anchorGap: anchorGap, opensAbove: opensAbove, usesFunnel: usesFunnel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GeniePopupHostView,
                      context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 340)
        let limit = max(1, proposal.height ?? UIScreen.main.bounds.height)
        // Settings has already measured its entire scroll column. Asking a
        // second hosting layout for an intrinsic size can shrink the viewport
        // again after the animation has started.
        if fillsProposedSize { return CGSize(width: width, height: limit) }
        let size = uiView.host.sizeThatFits(in: CGSize(width: width, height: limit))
        let fittedWidth = fitsContentWidth ? min(width, max(1, size.width)) : width
        return CGSize(width: fittedWidth, height: min(limit, max(1, size.height)))
    }

    static func dismantleUIView(_ view: GeniePopupHostView, coordinator: ()) {
        view.stop()
        view.host.willMove(toParent: nil)
        view.host.removeFromParent()
    }
}

@MainActor
final class GeniePopupHostView: UIView {
    private final class Triangle {
        let container = CALayer()
        let texture = CALayer()
        let mask = CAShapeLayer()

        init() {
            container.anchorPoint = .zero
            container.position = .zero
            container.masksToBounds = false
            container.addSublayer(texture)
            container.mask = mask
            texture.anchorPoint = .zero
            texture.position = .zero
            texture.contentsGravity = .resize
            texture.masksToBounds = true
        }

        func setMask(_ path: CGPath, size: CGSize) {
            mask.frame = CGRect(origin: .zero, size: size)
            mask.path = path
        }
    }

    private final class Band {
        let upper = Triangle()
        let lower = Triangle()
    }

    let host = UIHostingController(rootView: AnyView(EmptyView()))
    private let canvas = UIView()
    private let bands = (0..<GeniePopupMotion.renderBandCount).map { _ in Band() }
    private let capturePadding: CGFloat = 12
    private var capturedSize = CGSize.zero
    private var crossSections: [GeniePopupMotion.CrossSection] = []
    private var hasCapture = false
    private var capturing = false
    private var displayLink: CADisplayLink?
    private var progress: CGFloat = 0
    private var target: CGFloat = 0
    private var from: CGFloat = 0
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var anchorX: CGFloat = 0.5
    private var anchorWidth: CGFloat = 0.1
    private var anchorGap: CGFloat = 8
    private var lastDrawnProgress: CGFloat?
    private var settledTarget: CGFloat?
    private var opensAbove = false
    private var usesFunnel = true
    var onSettled: ((CGFloat) -> Void)?
    var onProgress: ((CGFloat) -> Void)?
    private var lastReportedProgress: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        addSubview(host.view)
        canvas.backgroundColor = .clear
        canvas.isUserInteractionEnabled = false
        canvas.clipsToBounds = false
        addSubview(canvas)
        for band in bands {
            canvas.layer.addSublayer(band.upper.container)
            canvas.layer.addSublayer(band.lower.container)
        }
        settle()
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
            return
        }
        if host.parent == nil {
            var responder: UIResponder? = next
            while let current = responder {
                if let parent = current as? UIViewController {
                    parent.addChild(host)
                    host.didMove(toParent: parent)
                    break
                }
                responder = current.next
            }
        }
        setNeedsLayout()
    }

    func configure(target next: CGFloat, anchorX: CGFloat,
                   anchorWidth: CGFloat, anchorGap: CGFloat, opensAbove: Bool = false, usesFunnel: Bool = true) {
        if self.anchorX != anchorX || self.anchorWidth != anchorWidth || self.anchorGap != anchorGap || self.opensAbove != opensAbove || self.usesFunnel != usesFunnel {
            lastDrawnProgress = nil
        }
        self.opensAbove = opensAbove
        self.usesFunnel = usesFunnel
        self.anchorX = anchorX
        self.anchorWidth = anchorWidth
        self.anchorGap = anchorGap
        let next = GeniePopupMotion.progress(next)
        if next != target {
            if next == progress { settledTarget = nil }
            target = next
            // Reverse from the currently drawn frame; no delayed completion
            // can unmount or hide a popup that has already been reopened.
            from = progress
            startedAt = CACurrentMediaTime()
            duration = GeniePopupMotion.duration(expanding: next > progress) * Double(abs(next - progress))
        }
        if progress != target {
            host.view.isUserInteractionEnabled = false
            host.view.accessibilityElementsHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
        canvas.frame = bounds
        guard !capturing, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if progress != target {
            // Capture on the next display frame, after the layout transaction,
            // rather than freezing the first, potentially incomplete hierarchy.
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            drawFrame()
        } else {
            settle()
        }
    }

    private func captureContent() -> Bool {
        capturing = true
        defer { capturing = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        host.view.layer.opacity = 1
        host.view.alpha = 1
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let rect = bounds.insetBy(dx: -capturePadding, dy: -capturePadding)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window?.screen.scale ?? UIScreen.main.scale
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: capturePadding, y: capturePadding)
            // Popup controls use snapshot-stable panel materials. Render the
            // laid-out layer, including its inset rim, while the live view is
            // hidden; drawHierarchy can return transparent data in this state.
            host.view.layer.render(in: context.cgContext)
        }
        host.view.layer.opacity = 0
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        guard let cgImage = image.cgImage else { return false }
        if capturedSize != bounds.size {
            capturedSize = bounds.size
            crossSections = (0...bands.count).map { index in
                // Use the same physical-pixel boundary as the cropped texture.
                let fraction = (CGFloat(index * cgImage.height / bands.count) / format.scale - capturePadding) / bounds.height
                return GeniePopupMotion.CrossSection(fraction: fraction)
            }
        }
        for (index, band) in bands.enumerated() {
            // Each triangle owns only its small source band. The container
            // mask is in destination coordinates, matching Android's two
            // clipped drawLayer calls for every band.
            let top = index * cgImage.height / bands.count
            let bottom = (index + 1) * cgImage.height / bands.count
            let contents = cgImage.cropping(to: CGRect(x: 0, y: top,
                                                        width: cgImage.width, height: bottom - top))
            for triangle in [band.upper, band.lower] {
                triangle.container.frame = canvas.bounds
                triangle.container.bounds = canvas.bounds
                triangle.texture.contents = contents
                triangle.texture.bounds = CGRect(x: 0, y: 0, width: rect.width,
                                                 height: CGFloat(bottom - top) / format.scale)
                triangle.texture.contentsScale = format.scale
                triangle.mask.contentsScale = format.scale
            }
        }
        hasCapture = true
        lastDrawnProgress = nil
        return true
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if !hasCapture || capturedSize != bounds.size {
            let firstCapture = !hasCapture
            guard captureContent() else { return }
            // Height changes during a transition refresh the full surface and
            // content together without restarting/reversing the animation clock.
            if firstCapture { startedAt = CACurrentMediaTime() }
        }
        let elapsed = link.timestamp - startedAt
        let fraction = min(1, max(0, elapsed / max(duration, 0.001)))
        if fraction >= 1 {
            progress = target
            settle()
            return
        }
        let eased = GeniePopupMotion.timing(fraction, expanding: target > from)
        progress = from + (target - from) * eased
        drawFrame()
    }

    private func drawFrame() {
        // Layout can run again without advancing the animation. Only rewrite
        // the 12-band transforms when progress, capture or attachment changed.
        guard hasCapture, lastDrawnProgress != progress else { return }
        lastDrawnProgress = progress
        reportProgress()
        renderFrame(at: progress)
    }

    /// Drawing is independent of the display clock so endpoint rendering can
    /// be checked exactly, without a screenshot racing the final display tick.
    func renderFrame(at progress: CGFloat) {
        guard hasCapture else { return }
        let size = capturedSize
        let paddingFraction = capturePadding / size.width
        let source = CGRect(
            x: anchorX * size.width - anchorWidth * size.width / 2,
            y: opensAbove ? size.height + anchorGap : -anchorGap,
            width: anchorWidth * size.width,
            height: 0
        )
        let panel = CGRect(origin: .zero, size: size)
        // RemoteParameterPanel is beside its anchor in landscape. Android's
        // validGenieAnchor rejects overlapping vertical spans and fades the
        // recorded layer at p, retaining the same open/close clock.
        let renderProgress: CGFloat = usesFunnel ? progress : 1
        let geometry = GeniePopupMotion.FrameGeometry(progress: renderProgress, source: source, size: size)
        func row(_ index: Int) -> GeniePopupMotion.Row {
            let section = crossSections[index]
            let original = opensAbove
                ? GeniePopupMotion.rowAbove(progress: renderProgress, fraction: section.fraction,
                                             anchor: source, panel: panel)
                : geometry.row(at: section)
            // The Android geometry clamps body fractions to 0...1. Our texture
            // additionally includes overflow outside that body. Preserve that
            // padding instead of squeezing it into the first/last content band;
            // otherwise the title and footer jump at the live-view handoff.
            let overflow = section.fraction - min(1, max(0, section.fraction))
            let length = renderProgress * (2 - renderProgress)
            return GeniePopupMotion.Row(left: original.left, right: original.right,
                y: original.y + overflow * size.height * length, tilt: original.tilt)
                .padded(by: paddingFraction)
        }
        var top = row(0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, band) in bands.enumerated() {
            let bottom = row(index + 1)
            let sourceSize = CGSize(width: band.upper.texture.bounds.width,
                                    height: band.upper.texture.bounds.height)
            let upperPath = CGMutablePath()
            upperPath.move(to: CGPoint(x: top.left, y: top.leftY))
            upperPath.addLine(to: CGPoint(x: top.right, y: top.rightY))
            upperPath.addLine(to: CGPoint(x: bottom.left, y: bottom.leftY))
            upperPath.closeSubpath()
            let lowerPath = CGMutablePath()
            lowerPath.move(to: CGPoint(x: top.right, y: top.rightY))
            lowerPath.addLine(to: CGPoint(x: bottom.right, y: bottom.rightY))
            lowerPath.addLine(to: CGPoint(x: bottom.left, y: bottom.leftY))
            lowerPath.closeSubpath()
            band.upper.setMask(upperPath, size: size)
            band.lower.setMask(lowerPath, size: size)
            band.upper.texture.transform = GeniePopupMotion.bandTransform(
                size: sourceSize, top: top, bottom: bottom, upper: true)
            band.lower.texture.transform = GeniePopupMotion.bandTransform(
                size: sourceSize, top: top, bottom: bottom, upper: false)
            // Adjacent bands share this exact edge. Evaluate its power curve
            // and padding once, then reuse the row for the next band.
            top = bottom
        }
        let alpha = usesFunnel ? GeniePopupMotion.opacity(progress)
            : (GeniePopupMotion.opacity(progress) > 0 ? progress : 0)
        if canvas.alpha != alpha { canvas.alpha = alpha }
        let hidden = progress <= 0
        if canvas.isHidden != hidden { canvas.isHidden = hidden }
        CATransaction.commit()
    }

    private func settle() {
        // Content/layout updates can visit this method while already idle.
        // The outer UIKit visibility flags have not changed in that case.
        guard settledTarget != target || hasCapture || displayLink != nil else { return }
        // Also handles a reversal back to the current endpoint before the
        // first tick: an already settled popup needs no display-link callback.
        stop()
        // Plain CALayers can otherwise implicitly animate contents=nil,
        // keeping discarded captures alive after the canvas is hidden.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.isHidden = true
        host.view.layer.opacity = target == 0 ? 0 : 1
        host.view.isUserInteractionEnabled = target == 1
        host.view.accessibilityElementsHidden = target == 0
        if hasCapture {
            hasCapture = false
            lastDrawnProgress = nil
            for band in bands {
                band.upper.texture.contents = nil
                band.lower.texture.contents = nil
            }
        }
        CATransaction.commit()
        settledTarget = target
        reportProgress()
        let settled = target
        if let onSettled { DispatchQueue.main.async { onSettled(settled) } }
    }

    /// Scrims use the same displayed progress as the mesh. Deliver outside
    /// layout so SwiftUI state writes cannot recursively invalidate this pass.
    /// A queued frame superseded by a reversal must never unmount its owner.
    private func reportProgress() {
        guard onProgress != nil, lastReportedProgress != progress else { return }
        lastReportedProgress = progress
        let value = progress
        DispatchQueue.main.async { [weak self] in
            guard let self, self.progress == value else { return }
            self.onProgress?(value)
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

/// Resolve the trigger in the popup's own GeometryReader during the same
/// layout pass. No @State/CGRect handoff, global-coordinate conversion or
/// synthetic fallback is involved. Bounds are outside the button's press
/// effect, so feedback does not move the attachment edge.
enum GeniePopupTrigger: String, Hashable {
    case queueRetry, queueClear
    case filter, settings, gps, remoteWhiteBalance, remoteFocusArea, remoteFocusMode, remoteGrid
    case remoteEV, remoteISO, remoteAperture, remoteShutter
}

extension RemoteExposureField {
    var popupTrigger: GeniePopupTrigger {
        switch self {
        case .exposureCompensation: .remoteEV
        case .iso: .remoteISO
        case .aperture: .remoteAperture
        case .shutter: .remoteShutter
        }
    }
}

struct GeniePopupAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [GeniePopupTrigger: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [GeniePopupTrigger: Anchor<CGRect>],
                       nextValue: () -> [GeniePopupTrigger: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func geniePopupAnchor(_ trigger: GeniePopupTrigger) -> some View {
        anchorPreference(key: GeniePopupAnchorPreferenceKey.self, value: .bounds) {
            [trigger: $0]
        }
    }
}
