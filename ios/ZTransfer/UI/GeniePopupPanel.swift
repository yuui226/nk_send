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

    func makeUIView(context: Context) -> GeniePopupHostView {
        let view = GeniePopupHostView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: GeniePopupHostView, context: Context) {
        view.host.rootView = AnyView(content.environment(\.self, context.environment))
        view.accessibilityIdentifier = "popup-panel-\(trigger.rawValue)"
        view.configure(target: targetProgress, anchorX: anchorX,
                       anchorWidth: anchorWidth, anchorGap: anchorGap)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GeniePopupHostView,
                      context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 340)
        let limit = max(1, proposal.height ?? UIScreen.main.bounds.height)
        let size = uiView.host.sizeThatFits(in: CGSize(width: width, height: limit))
        return CGSize(width: width, height: min(limit, max(1, size.height)))
    }

    static func dismantleUIView(_ view: GeniePopupHostView, coordinator: ()) {
        view.stop()
        view.host.willMove(toParent: nil)
        view.host.removeFromParent()
    }
}

@MainActor
final class GeniePopupHostView: UIView {
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    private let canvas = UIView()
    private let bands = (0..<48).map { _ in CALayer() }
    private let capturePadding: CGFloat = 12
    private var capturedSize = CGSize.zero
    private var hasCapture = false
    private var displayLink: CADisplayLink?
    private var progress: CGFloat = 0
    private var target: CGFloat = 0
    private var from: CGFloat = 0
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var anchorX: CGFloat = 0.5
    private var anchorWidth: CGFloat = 0.1
    private var anchorGap: CGFloat = 8

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
            band.anchorPoint = .zero
            band.position = .zero
            band.masksToBounds = true
            band.contentsGravity = .resize
            canvas.layer.addSublayer(band)
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
                   anchorWidth: CGFloat, anchorGap: CGFloat) {
        self.anchorX = anchorX
        self.anchorWidth = anchorWidth
        self.anchorGap = anchorGap
        let next = GeniePopupMotion.progress(next)
        if next != target {
            target = next
            // Reverse from the currently drawn frame; no delayed completion
            // can unmount or hide a popup that has already been reopened.
            from = progress
            startedAt = CACurrentMediaTime()
            duration = GeniePopupMotion.duration(expanding: next > progress) * Double(abs(next - progress))
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = bounds
        canvas.frame = bounds
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if progress != target {
            if !hasCapture {
                captureContent()
                // Layout/capture time is not part of the visible animation.
                startedAt = CACurrentMediaTime()
            }
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

    private func captureContent() {
        host.view.layer.opacity = 1
        host.view.alpha = 1
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let rect = bounds.insetBy(dx: -capturePadding, dy: -capturePadding)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window?.screen.scale ?? UIScreen.main.scale
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: capturePadding, y: capturePadding)
            host.view.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage else { return }
        capturedSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, band) in bands.enumerated() {
            // Each layer owns only its small band, never a full-panel-sized
            // surface behind a mask. Total backing area stays about one panel.
            let top = index * cgImage.height / bands.count
            let bottom = (index + 1) * cgImage.height / bands.count
            band.contents = cgImage.cropping(to: CGRect(x: 0, y: top,
                                                       width: cgImage.width, height: bottom - top))
            band.bounds = CGRect(x: 0, y: 0, width: rect.width,
                                 height: CGFloat(bottom - top) / format.scale)
            band.contentsScale = format.scale
        }
        CATransaction.commit()
        hasCapture = true
        host.view.layer.opacity = 0
        canvas.isHidden = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = link.timestamp - startedAt
        let fraction = min(1, max(0, elapsed / max(duration, 0.001)))
        let eased = GeniePopupMotion.timing(fraction, expanding: target > from)
        progress = from + (target - from) * eased
        if fraction >= 1 {
            progress = target
            stop()
            settle()
        } else {
            drawFrame()
        }
    }

    private func drawFrame() {
        guard hasCapture else { return }
        let size = capturedSize
        let paddedHeight = size.height + 2 * capturePadding
        let source = CGRect(x: anchorX * size.width - anchorWidth * size.width / 2,
                            y: -anchorGap, width: anchorWidth * size.width, height: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, band) in bands.enumerated() {
            let topFraction = (CGFloat(index) / CGFloat(bands.count) * paddedHeight - capturePadding) / size.height
            let bottomFraction = (CGFloat(index + 1) / CGFloat(bands.count) * paddedHeight - capturePadding) / size.height
            let top = GeniePopupMotion.row(progress: progress, fraction: topFraction, source: source, size: size)
            let bottom = GeniePopupMotion.row(progress: progress, fraction: bottomFraction, source: source, size: size)
            band.transform = GeniePopupMotion.bandTransform(
                size: band.bounds.size,
                top: top.padded(by: capturePadding / size.width),
                bottom: bottom.padded(by: capturePadding / size.width)
            )
        }
        canvas.alpha = GeniePopupMotion.opacity(progress)
        canvas.isHidden = progress <= 0
        host.view.layer.opacity = 0
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        CATransaction.commit()
    }

    private func settle() {
        canvas.isHidden = true
        host.view.layer.opacity = target == 0 ? 0 : 1
        host.view.isUserInteractionEnabled = target == 1
        host.view.accessibilityElementsHidden = target == 0
        hasCapture = false
        for band in bands { band.contents = nil }
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
    case filter, settings, gps
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
