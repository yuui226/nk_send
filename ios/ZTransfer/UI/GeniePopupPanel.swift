import SwiftUI
import UIKit

/// Hosts the live SwiftUI settings tree and renders a short-lived, segmented
/// snapshot while it travels between the settings button and the panel.
///
/// The Android implementation uses a GPU mesh. On iOS the same rows are
/// represented by twelve cropped UIImageViews, which keeps the transition in
/// UIKit and avoids requiring an optional Metal compiler component in Xcode.
@MainActor struct GeniePopupPanel<Content: View>: UIViewRepresentable {
    let content: Content
    let targetProgress: CGFloat
    let anchor: CGRect
    let panelOrigin: CGPoint
    let viewport: CGSize
    let onCollapsed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    func makeUIView(context: Context) -> GeniePanelContainer {
        let container = GeniePanelContainer(host: context.coordinator.host)
        container.updateGeometry(anchor: anchor, panelOrigin: panelOrigin, viewport: viewport)
        container.onCollapsed = onCollapsed
        return container
    }

    func updateUIView(_ uiView: GeniePanelContainer, context: Context) {
        context.coordinator.host.rootView = AnyView(content)
        uiView.updateGeometry(anchor: anchor, panelOrigin: panelOrigin, viewport: viewport)
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
    var onCollapsed: (() -> Void)?

    private let meshView = UIView(frame: .zero)
    private var strips: [UIImageView] = []
    private var snapshotSize: CGSize = .zero
    private var anchor: CGRect = .zero
    private var panelOrigin: CGPoint = .zero
    private var viewport: CGSize = .zero
    private var currentProgress: CGFloat = 0
    private var requestedProgress: CGFloat = 0
    private var runningTarget: CGFloat?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var startedFrom: CGFloat = 0
    private var duration: TimeInterval = 0

    init(host: UIHostingController<AnyView>) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false

        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        meshView.backgroundColor = .clear
        meshView.isUserInteractionEnabled = false
        meshView.isHidden = true
        meshView.layer.allowsEdgeAntialiasing = true
        addSubview(meshView)
        host.view.isHidden = true
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
        meshView.frame = bounds
        if requestedProgress != currentProgress && runningTarget != requestedProgress &&
            bounds.width > 0 && bounds.height > 0 {
            beginTransition(to: requestedProgress)
        }
        renderFrame()
    }

    func updateGeometry(anchor: CGRect, panelOrigin: CGPoint, viewport: CGSize) {
        self.anchor = anchor
        self.panelOrigin = panelOrigin
        self.viewport = viewport
        setNeedsLayout()
    }

    func requestProgress(_ rawTarget: CGFloat) {
        let target = GeniePopupMotion.progress(rawTarget)
        guard requestedProgress != target ||
                (runningTarget == nil && currentProgress != target) else { return }
        requestedProgress = target
        // Closing before the opening layout pass still completes dismissal.
        if currentProgress == target {
            finish(at: target)
            return
        }
        // Capture only after SwiftUI has applied the measured content height.
        // Starting here could snapshot the previous, full-height bounds.
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
        // Re-capture on close so edited controls and a visited detail page are
        // represented by the exact panel the user is dismissing.
        if target == 0 || strips.isEmpty {
            capturePanel()
        }
        guard !strips.isEmpty else {
            finish(at: target)
            return
        }

        host.view.isHidden = true
        meshView.isHidden = false
        startedFrom = currentProgress
        runningTarget = target
        duration = target == 1
            ? GeniePopupMotion.expandDuration * Double(1 - currentProgress)
            : GeniePopupMotion.collapseDuration * Double(currentProgress)
        duration = max(0.001, duration)
        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        renderFrame()
    }

    private func capturePanel() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let wasHidden = host.view.isHidden
        host.view.isHidden = false
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window?.screen.scale ?? UIScreen.main.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { output in
            host.view.layer.render(in: output.cgContext)
        }
        host.view.isHidden = wasHidden
        installStrips(from: image)
    }

    private func installStrips(from image: UIImage) {
        strips.forEach { $0.removeFromSuperview() }
        strips.removeAll(keepingCapacity: true)
        snapshotSize = image.size
        guard image.size.width > 0, image.size.height > 0,
              let cgImage = image.cgImage else { return }

        let bands = GeniePopupMotion.renderBands
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let pixelOverlap = max(1, Int(ceil(window?.screen.scale ?? UIScreen.main.scale)))
        for index in 0..<bands {
            // Neighboring transformed strips can land on opposite sides of a
            // fractional pixel. Overlap their source rows by one screen pixel
            // so antialiased edges never expose a hairline of the clear mesh.
            let start = max(0, Int(floor(Double(index) * Double(pixelHeight) / Double(bands))) - pixelOverlap)
            let end = max(start + 1,
                          min(pixelHeight,
                              Int(ceil(Double(index + 1) * Double(pixelHeight) / Double(bands))) + pixelOverlap))
            let crop = CGRect(x: 0, y: start, width: pixelWidth,
                              height: min(pixelHeight - start, end - start))
            guard let part = cgImage.cropping(to: crop) else { continue }
            let strip = UIImageView(image: UIImage(cgImage: part,
                                                    scale: image.scale,
                                                    orientation: image.imageOrientation))
            strip.backgroundColor = .clear
            strip.contentMode = .scaleToFill
            strip.isUserInteractionEnabled = false
            // The strips are continuously rotated and resampled while the
            // panel travels from the Z button. Explicit linear filtering and
            // edge antialiasing avoid the stair-stepped diagonal seams that
            // UIKit otherwise produces for transformed image views.
            strip.layer.allowsEdgeAntialiasing = true
            strip.layer.magnificationFilter = .linear
            strip.layer.minificationFilter = .trilinear
            strip.layer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            meshView.addSubview(strip)
            strips.append(strip)
        }
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
        guard !strips.isEmpty, snapshotSize.width > 0, snapshotSize.height > 0 else { return }
        let panel = CGRect(origin: panelOrigin, size: bounds.size)
        let source = GeniePopupMotion.validAnchor(anchor, panel: panel)
            ? anchor
            : CGRect(x: panel.minX + 8, y: panel.minY - 44, width: 36, height: 36)
        let bands = GeniePopupMotion.renderBands
        let screenScale = window?.screen.scale ?? UIScreen.main.scale
        let overlap = 2 / max(screenScale, 1)
        let sourceBandHeight = max(1, snapshotSize.height / CGFloat(bands)) + overlap
        let alpha = GeniePopupMotion.panelAlpha(currentProgress)

        for index in 0..<min(bands, strips.count) {
            let fraction = CGFloat(index) / CGFloat(bands)
            let nextFraction = CGFloat(index + 1) / CGFloat(bands)
            let top = GeniePopupMotion.row(progress: currentProgress, fraction: fraction,
                                           anchor: source, panel: panel)
            let bottom = GeniePopupMotion.row(progress: currentProgress, fraction: nextFraction,
                                              anchor: source, panel: panel)
            let left = min(top.left, bottom.left)
            let right = max(top.right, bottom.right)
            let topY = min(top.leftY, top.rightY)
            let bottomY = max(bottom.leftY, bottom.rightY)
            let width = max(0.5, right - left)
            // Expand each band by a small amount in both directions. This is
            // the destination-side counterpart to the source overlap above;
            // it closes fractional-pixel seams while preserving the mesh's
            // silhouette and keeps UIKit's edge antialiasing effective.
            let height = max(0.5, bottomY - topY) + overlap
            let center = CGPoint(x: (left + right) / 2,
                                 y: (topY + bottomY) / 2)
            let tilt = ((top.rightY - top.leftY) + (bottom.rightY - bottom.leftY)) / 2
            let angle = atan2(tilt, max(width, 1))
            let strip = strips[index]
            strip.bounds = CGRect(x: 0, y: 0,
                                  width: max(1, snapshotSize.width),
                                  height: sourceBandHeight)
            strip.center = center
            strip.transform = CGAffineTransform(scaleX: width / max(1, snapshotSize.width),
                                                 y: height / sourceBandHeight)
                .rotated(by: angle)
            strip.alpha = alpha
        }
    }

    private func finish(at target: CGFloat) {
        stopDisplayLink()
        runningTarget = nil
        currentProgress = target
        meshView.isHidden = true
        host.view.isHidden = target != 1
        if target == 0 { onCollapsed?() }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func teardown() {
        stopDisplayLink()
        onCollapsed = nil
        if host.parent != nil {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }
}
