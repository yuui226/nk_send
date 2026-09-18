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
        // clear render gutter so Metal never clips that part of the mesh.
        meshView.frame = bounds.insetBy(dx: -canvasPadding, dy: -canvasPadding)
        if requestedProgress != currentProgress && runningTarget != requestedProgress &&
            bounds.width > 0 && bounds.height > 0 {
            beginTransition(to: requestedProgress)
        }
        renderFrame()
    }

    func updateGeometry(anchor: CGRect, panelOrigin: CGPoint, viewport _: CGSize) {
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
            capturePanel()
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
        renderFrame()
    }

    /// `drawHierarchy` includes UIVisualEffect/material pixels, unlike
    /// CALayer.render. The live view is exposed only inside this uncommitted
    /// transaction, so GPS never flashes a different background colour.
    private func capturePanel() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let previousOpacity = host.view.layer.opacity
        let previousHidden = host.view.isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.view.isHidden = false
        host.view.layer.opacity = 1
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window?.screen.scale ?? UIScreen.main.scale
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            // We are already inside the committed layout pass. Waiting for a
            // *future* screen update here deadlocks the main run loop at the
            // mouth frame; capture the current fully-laid-out hierarchy.
            if !host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false) {
                host.view.layer.render(in: context.cgContext)
            }
        }
        host.view.layer.opacity = previousOpacity
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
        var rows: [GeniePopupMotion.Row] = []
        rows.reserveCapacity(bands + 1)
        for index in 0...bands {
            rows.append(GeniePopupMotion.row(
                progress: currentProgress,
                fraction: CGFloat(index) / CGFloat(bands),
                anchor: source,
                panel: panel,
                mouthWidth: source.width
            ))
        }
        meshView.update(
            rows: rows,
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
        let source: (CGPoint, CGPoint, CGPoint)
    }

    private var triangles: [Triangle] = []
    private var imageSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        layer.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    func setSnapshot(_ image: UIImage) {
        clearSnapshot()
        guard let cgImage = image.cgImage, image.size.width > 0, image.size.height > 0 else { return }
        imageSize = image.size
        let bandHeight = image.size.height / CGFloat(GeniePopupMotion.renderBands)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for band in 0..<GeniePopupMotion.renderBands {
            let top = CGFloat(band) * bandHeight
            let bottom = band == GeniePopupMotion.renderBands - 1
                ? image.size.height
                : CGFloat(band + 1) * bandHeight
            let upper = (
                CGPoint(x: 0, y: top),
                CGPoint(x: image.size.width, y: top),
                CGPoint(x: 0, y: bottom)
            )
            let lower = (
                CGPoint(x: image.size.width, y: bottom),
                CGPoint(x: 0, y: bottom),
                CGPoint(x: image.size.width, y: top)
            )
            triangles.append(makeTriangle(image: cgImage, scale: image.scale, source: upper))
            triangles.append(makeTriangle(image: cgImage, scale: image.scale, source: lower))
        }
        CATransaction.commit()
    }

    func clearSnapshot() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        triangles.forEach { $0.layer.removeFromSuperlayer() }
        triangles.removeAll(keepingCapacity: true)
        imageSize = .zero
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
            apply(upperDestination, to: triangles[band * 2])
            apply(lowerDestination, to: triangles[band * 2 + 1])
        }
        CATransaction.commit()
    }

    private func makeTriangle(image: CGImage, scale: CGFloat,
                              source: (CGPoint, CGPoint, CGPoint)) -> Triangle {
        let imageLayer = CALayer()
        imageLayer.bounds = CGRect(origin: .zero, size: imageSize)
        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        imageLayer.contents = image
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
        return Triangle(layer: imageLayer, source: source)
    }

    private func apply(_ destination: (CGPoint, CGPoint, CGPoint), to triangle: Triangle) {
        guard let transform = affineMap(from: triangle.source, to: destination) else { return }
        triangle.layer.setAffineTransform(transform)
    }

    /// Unique affine map through three non-collinear point pairs.
    private func affineMap(from source: (CGPoint, CGPoint, CGPoint),
                           to destination: (CGPoint, CGPoint, CGPoint)) -> CGAffineTransform? {
        let (s0, s1, s2) = source
        let (d0, d1, d2) = destination
        let determinant = s0.x * (s1.y - s2.y) +
            s1.x * (s2.y - s0.y) + s2.x * (s0.y - s1.y)
        guard abs(determinant) > .ulpOfOne else { return nil }
        func coefficients(_ v0: CGFloat, _ v1: CGFloat, _ v2: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            let first = (v0 * (s1.y - s2.y) + v1 * (s2.y - s0.y) +
                v2 * (s0.y - s1.y)) / determinant
            let second = (v0 * (s2.x - s1.x) + v1 * (s0.x - s2.x) +
                v2 * (s1.x - s0.x)) / determinant
            let offset = (v0 * (s1.x * s2.y - s2.x * s1.y) +
                v1 * (s2.x * s0.y - s0.x * s2.y) +
                v2 * (s0.x * s1.y - s1.x * s0.y)) / determinant
            return (first, second, offset)
        }
        let x = coefficients(d0.x, d1.x, d2.x)
        let y = coefficients(d0.y, d1.y, d2.y)
        return CGAffineTransform(a: x.0, b: y.0, c: x.1, d: y.1, tx: x.2, ty: y.2)
    }
}
