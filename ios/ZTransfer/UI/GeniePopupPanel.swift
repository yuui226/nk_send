import SwiftUI
import UIKit

/// Android records the settled popup once and bends that texture with a small
/// triangle mesh. iOS follows the same path with public Core Animation layers:
/// SwiftUI is laid out only at its final size, one hierarchy snapshot is shared
/// by a fixed triangle mesh, and only affine transforms change during the
/// 320/350 ms transition. This is ready on the first tap and needs no runtime
/// shader compilation or extra Xcode Metal toolchain.
@MainActor struct GeniePopupPanel<Content: View>: UIViewRepresentable {
    let content: Content
    let targetProgress: CGFloat
    let anchor: CGRect
    let panelOrigin: CGPoint
    let viewport: CGSize
    var onExpanded: () -> Void = {}
    let onCollapsed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    func makeUIView(context: Context) -> GeniePanelContainer {
        let container = GeniePanelContainer(host: context.coordinator.host)
        container.updateGeometry(anchor: anchor, panelOrigin: panelOrigin, viewport: viewport)
        container.onExpanded = onExpanded
        container.onCollapsed = onCollapsed
        return container
    }

    func updateUIView(_ uiView: GeniePanelContainer, context: Context) {
        context.coordinator.host.rootView = AnyView(content)
        uiView.updateGeometry(anchor: anchor, panelOrigin: panelOrigin, viewport: viewport)
        uiView.onExpanded = onExpanded
        uiView.onCollapsed = onCollapsed
        uiView.requestProgress(targetProgress)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GeniePanelContainer,
                      context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? viewport.width - 24)
        let maximumHeight = max(1, proposal.height ?? viewport.height)
        let measured = context.coordinator.host.sizeThatFits(
            in: CGSize(width: width, height: maximumHeight)
        )
        return CGSize(width: width, height: min(maximumHeight, max(1, measured.height)))
    }

    static func dismantleUIView(_ uiView: GeniePanelContainer, coordinator: Coordinator) {
        uiView.teardown()
    }

    @MainActor final class Coordinator {
        let host: UIHostingController<AnyView>

        init(content: Content) {
            host = UIHostingController(rootView: AnyView(content))
            host.view.backgroundColor = .clear
        }
    }
}

@MainActor final class GeniePanelContainer: UIView {
    let host: UIHostingController<AnyView>
    var onExpanded: (() -> Void)?
    var onCollapsed: (() -> Void)?

    private let meshView = GenieTriangleCanvas(frame: .zero)
    private let canvasPadding: CGFloat = 24
    private var anchor: CGRect = .zero
    private var panelOrigin: CGPoint = .zero
    private var currentProgress: CGFloat = 0
    private var requestedProgress: CGFloat = 0
    private var runningTarget: CGFloat?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var startedFrom: CGFloat = 0
    private var duration: TimeInterval = 0
    private var snapshotReady = false
    private var rowBuffer = Array(
        repeating: GeniePopupMotion.Row(left: 0, right: 0, y: 0, tilt: 0),
        count: GeniePopupMotion.renderBands + 1
    )

    init(host: UIHostingController<AnyView>) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false

        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        host.view.layer.opacity = 0
        host.view.isUserInteractionEnabled = false

        meshView.isHidden = true
        meshView.isUserInteractionEnabled = false
        addSubview(meshView)
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, host.parent == nil else { return }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // The button mouth lives in the 8/10 pt gap above the panel. Keep a
        // clear render gutter so the triangle mesh never clips that part.
        meshView.frame = bounds.insetBy(dx: -canvasPadding, dy: -canvasPadding)
        if requestedProgress != currentProgress && runningTarget != requestedProgress &&
            bounds.width > 0 && bounds.height > 0 {
            beginTransition(to: requestedProgress)
        }
        // `beginTransition` renders its first frame. Settled panels must not
        // keep recalculating hidden mesh matrices on unrelated SwiftUI layout.
        if runningTarget != nil { renderFrame() }
    }

    func updateGeometry(anchor: CGRect, panelOrigin: CGPoint, viewport _: CGSize) {
        guard self.anchor != anchor || self.panelOrigin != panelOrigin else { return }
        self.anchor = anchor
        self.panelOrigin = panelOrigin
        setNeedsLayout()
    }

    func requestProgress(_ rawTarget: CGFloat) {
        let target = GeniePopupMotion.progress(rawTarget)
        guard requestedProgress != target ||
                (runningTarget == nil && currentProgress != target) else { return }
        requestedProgress = target
        if currentProgress == target {
            finish(at: target)
            return
        }
        setNeedsLayout()
    }

    private func beginTransition(to target: CGFloat) {
        guard runningTarget != target else { return }
        stopDisplayLink()
        if currentProgress == target {
            finish(at: target)
            return
        }

        host.view.layoutIfNeeded()
        // Opening captures once after final measurement. Closing captures the
        // current live controls once; interrupted transitions reuse the texture
        // already in flight instead of forcing another hierarchy render.
        if !snapshotReady || (target == 0 && currentProgress >= 0.9999) {
            capturePanel(useVisibleHierarchy: target == 0 && currentProgress >= 0.9999)
        }
        host.view.isUserInteractionEnabled = false
        host.view.layer.opacity = 0
        meshView.isHidden = false

        startedFrom = currentProgress
        runningTarget = target
        duration = target == 1
            ? GeniePopupMotion.expandDuration * Double(1 - currentProgress)
            : GeniePopupMotion.collapseDuration * Double(currentProgress)
        duration = max(0.001, duration)
        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 120, preferred: 120
            )
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// `drawHierarchy` includes UIVisualEffect/material pixels, unlike
    /// CALayer.render. The live view is exposed only inside this uncommitted
    /// transaction, so GPS never flashes a different background colour.
    private func capturePanel(useVisibleHierarchy: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let previousAlpha = host.view.alpha
        let previousHidden = host.view.isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.view.isHidden = false
        // `drawHierarchy` consults UIView state. Updating `alpha`, instead of
        // only the backing layer's model value, prevents a newly mounted host
        // whose presentation opacity is still zero from producing a fully
        // transparent opening texture.
        host.view.alpha = 1
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window?.screen.scale ?? UIScreen.main.scale
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let image = renderer.image { context in
            if useVisibleHierarchy {
                // Collapse starts from a hierarchy that is already on screen,
                // so this path retains native material pixels accurately.
                if !host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false) {
                    host.view.layer.render(in: context.cgContext)
                }
            } else {
                // During first expansion the hosting view has final layout but
                // no committed visible presentation yet. drawHierarchy can
                // report success while producing a transparent bitmap. Render
                // the model layer directly: deterministic, one pass, and no
                // full-image validation readback on the main thread.
                host.view.layer.render(in: context.cgContext)
            }
        }
        host.view.alpha = previousAlpha
        host.view.isHidden = previousHidden
        CATransaction.commit()

        meshView.setSnapshot(image)
        snapshotReady = true
    }

    @objc private func tick() {
        guard let target = runningTarget else { return }
        let elapsed = CACurrentMediaTime() - startedAt
        let fraction = GeniePopupMotion.progress(CGFloat(elapsed / duration))
        let eased = GeniePopupMotion.ease(fraction, expanding: target == 1)
        currentProgress = startedFrom + (target - startedFrom) * eased
        renderFrame()
        if fraction >= 1 { finish(at: target) }
    }

    private func renderFrame() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let panel = CGRect(origin: panelOrigin, size: bounds.size)
        let source = GeniePopupMotion.validAnchor(anchor, panel: panel)
            ? anchor
            : CGRect(x: panel.minX + 8, y: panel.minY - 44, width: 36, height: 36)
        // Keep Android's full twelve-band geometry through the handoff. The
        // layers are allocated once per snapshot, so retaining all bands does
        // not add per-frame allocation and avoids a visible topology switch.
        let bands = GeniePopupMotion.renderBands
        for index in 0...bands {
            rowBuffer[index] = GeniePopupMotion.row(
                progress: currentProgress,
                fraction: CGFloat(index) / CGFloat(bands),
                anchor: source,
                panel: panel,
                mouthWidth: source.width
            )
        }
        meshView.update(
            rows: rowBuffer,
            padding: canvasPadding,
            alpha: GeniePopupMotion.panelAlpha(currentProgress)
        )
    }

    private func finish(at target: CGFloat) {
        stopDisplayLink()
        runningTarget = nil
        currentProgress = target
        meshView.isHidden = true
        host.view.layer.opacity = target == 1 ? 1 : 0
        host.view.isUserInteractionEnabled = target == 1
        if target == 1 {
            // Closing always captures the then-current controls again. The
            // opening bitmap is therefore dead weight once live content takes
            // over; release it while retaining the small mesh skeleton.
            snapshotReady = false
            meshView.releaseSnapshot()
            onExpanded?()
        } else {
            snapshotReady = false
            meshView.clearSnapshot()
            onCollapsed?()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func teardown() {
        stopDisplayLink()
        meshView.clearSnapshot()
        onExpanded = nil
        onCollapsed = nil
        if host.parent != nil {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }
}

/// A fixed 12-band mesh made from two affine triangles per band. Every layer
/// references the same CGImage; only its transform changes on display-link
/// ticks. This preserves the curved Android geometry without per-frame
/// snapshots, SwiftUI layout, masks, or shader compilation.
private final class GenieTriangleCanvas: UIView {
    private struct Triangle {
        let layer: CALayer
    }

    private var triangles: [Triangle] = []
    private var configuredSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        layer.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    func setSnapshot(_ image: UIImage) {
        guard let cgImage = image.cgImage, image.size.width > 0, image.size.height > 0 else { return }
        if triangles.count == GeniePopupMotion.renderBands * 2,
           configuredSize == image.size {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            triangles.forEach {
                $0.layer.contents = cgImage
                $0.layer.contentsScale = image.scale
            }
            CATransaction.commit()
            return
        }

        clearSnapshot()
        configuredSize = image.size
        let bandHeight = image.size.height / CGFloat(GeniePopupMotion.renderBands)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for band in 0..<GeniePopupMotion.renderBands {
            let top = CGFloat(band) * bandHeight
            let bottom = band == GeniePopupMotion.renderBands - 1
                ? image.size.height
                : CGFloat(band + 1) * bandHeight
            let height = bottom - top
            let bandSize = CGSize(width: image.size.width, height: height)
            let contentsRect = CGRect(
                x: 0,
                y: top / image.size.height,
                width: 1,
                height: height / image.size.height
            )
            // Each layer owns only one band-sized render surface. The CGImage
            // remains shared, while contentsRect selects the required rows.
            // The previous full-panel bounds caused 24 complete offscreen
            // passes and could freeze the photo list when Filter was tapped.
            let upper = (
                CGPoint(x: 0, y: 0),
                CGPoint(x: image.size.width, y: 0),
                CGPoint(x: 0, y: height)
            )
            let lower = (
                CGPoint(x: image.size.width, y: height),
                CGPoint(x: 0, y: height),
                CGPoint(x: image.size.width, y: 0)
            )
            triangles.append(makeTriangle(
                image: cgImage, scale: image.scale, size: bandSize,
                contentsRect: contentsRect, source: upper
            ))
            triangles.append(makeTriangle(
                image: cgImage, scale: image.scale, size: bandSize,
                contentsRect: contentsRect, source: lower
            ))
        }
        CATransaction.commit()
    }

    /// Drop the large bitmap immediately after handoff, but retain the tiny
    /// layer/mask skeleton so collapse can reuse it without 48 allocations.
    func releaseSnapshot() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        triangles.forEach { $0.layer.contents = nil }
        layer.opacity = 0
        CATransaction.commit()
    }

    func clearSnapshot() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        triangles.forEach { $0.layer.removeFromSuperlayer() }
        triangles.removeAll(keepingCapacity: true)
        configuredSize = .zero
        layer.opacity = 0
        CATransaction.commit()
    }

    func update(rows: [GeniePopupMotion.Row], padding: CGFloat, alpha: CGFloat) {
        guard rows.count == GeniePopupMotion.renderBands + 1,
              triangles.count == GeniePopupMotion.renderBands * 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Float(min(1, max(0, alpha)))
        for band in 0..<GeniePopupMotion.renderBands {
            let top = rows[band]
            let bottom = rows[band + 1]
            let upperDestination = (
                CGPoint(x: top.left + padding, y: top.leftY + padding),
                CGPoint(x: top.right + padding, y: top.rightY + padding),
                CGPoint(x: bottom.left + padding, y: bottom.leftY + padding)
            )
            let lowerDestination = (
                CGPoint(x: bottom.right + padding, y: bottom.rightY + padding),
                CGPoint(x: bottom.left + padding, y: bottom.leftY + padding),
                CGPoint(x: top.right + padding, y: top.rightY + padding)
            )
            applyUpper(upperDestination, to: triangles[band * 2].layer)
            applyLower(lowerDestination, to: triangles[band * 2 + 1].layer)
        }
        CATransaction.commit()
    }

    private func makeTriangle(image: CGImage, scale: CGFloat, size: CGSize,
                              contentsRect: CGRect,
                              source: (CGPoint, CGPoint, CGPoint)) -> Triangle {
        let imageLayer = CALayer()
        imageLayer.bounds = CGRect(origin: .zero, size: size)
        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        imageLayer.contents = image
        imageLayer.contentsRect = contentsRect
        imageLayer.contentsScale = scale
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        imageLayer.allowsEdgeAntialiasing = false
        imageLayer.edgeAntialiasingMask = []

        let mask = CAShapeLayer()
        mask.frame = imageLayer.bounds
        let path = CGMutablePath()
        path.move(to: source.0)
        path.addLine(to: source.1)
        path.addLine(to: source.2)
        path.closeSubpath()
        mask.path = path
        mask.fillColor = UIColor.white.cgColor
        mask.allowsEdgeAntialiasing = false
        imageLayer.mask = mask
        layer.addSublayer(imageLayer)
        return Triangle(layer: imageLayer)
    }

    private func applyUpper(_ destination: (CGPoint, CGPoint, CGPoint), to layer: CALayer) {
        let (topLeft, topRight, bottomLeft) = destination
        let width = max(1, layer.bounds.width)
        let height = max(1, layer.bounds.height)
        layer.setAffineTransform(CGAffineTransform(
            a: (topRight.x - topLeft.x) / width,
            b: (topRight.y - topLeft.y) / width,
            c: (bottomLeft.x - topLeft.x) / height,
            d: (bottomLeft.y - topLeft.y) / height,
            tx: topLeft.x,
            ty: topLeft.y
        ))
    }

    private func applyLower(_ destination: (CGPoint, CGPoint, CGPoint), to layer: CALayer) {
        let (bottomRight, bottomLeft, topRight) = destination
        let width = max(1, layer.bounds.width)
        let height = max(1, layer.bounds.height)
        let a = (bottomRight.x - bottomLeft.x) / width
        let b = (bottomRight.y - bottomLeft.y) / width
        let c = (bottomRight.x - topRight.x) / height
        let d = (bottomRight.y - topRight.y) / height
        layer.setAffineTransform(CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: bottomLeft.x - c * height,
            ty: bottomLeft.y - d * height
        ))
    }
}
