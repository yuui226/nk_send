import SwiftUI
import UIKit

/// Android ButtonStateTextMotion / GpsStatusButton. Only the glyph layers move;
/// the button's material, size and input ownership remain stable.
struct ButtonStateLabel: UIViewRepresentable {
    let text: String
    let rank: Int
    let color: Color
    var active = true
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> ButtonStateLabelView { ButtonStateLabelView() }
    func updateUIView(_ view: ButtonStateLabelView, context: Context) {
        view.configure(text: text, rank: rank, color: UIColor(color),
                       active: active && scenePhase == .active)
    }
    static func dismantleUIView(_ view: ButtonStateLabelView, coordinator: ()) { view.settle() }
}

final class ButtonStateLabelView: UIView {
    private var labels: [Int: UILabel] = [:]
    private var currentRank: Int?
    private var generation = 0
    private let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { nil }

    func configure(text: String, rank: Int, color: UIColor, active: Bool) {
        labels.values.forEach { $0.textColor = color }
        guard rank != currentRank else {
            labels[rank]?.text = text
            if !active { settle() }
            return
        }
        let previous = currentRank
        let direction: CGFloat = rank >= (previous ?? rank) ? 1 : -1
        currentRank = rank
        generation &+= 1
        let token = generation
        let existing = labels[rank]
        let incoming = existing ?? UILabel()
        incoming.text = text
        incoming.textColor = color
        if existing == nil {
            incoming.font = .systemFont(ofSize: 14, weight: .semibold)
            incoming.textAlignment = .center
            incoming.lineBreakMode = .byClipping
            incoming.isAccessibilityElement = false
            labels[rank] = incoming
            addSubview(incoming)
            incoming.frame = bounds
        }
        guard active, previous != nil, window != nil, bounds.height > 0 else {
            settle()
            return
        }
        for (key, label) in labels {
            let entering = key == rank
            // A reverse or another status can arrive before 220 ms. Retarget
            // from the rendered position/alpha, including an outgoing label
            // that becomes current again; never queue stale status messages.
            let displayed = label.layer.presentation() ?? label.layer
            let startY = entering && existing == nil ? bounds.height * direction : displayed.transform.m42
            let startAlpha = entering && existing == nil ? Float(0) : displayed.opacity
            label.layer.removeAllAnimations()
            let endY: CGFloat = entering ? 0 : -bounds.height * direction
            let endAlpha: Float = entering ? 1 : 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            label.layer.transform = CATransform3DMakeTranslation(0, endY, 0)
            label.layer.opacity = endAlpha
            if !entering {
                CATransaction.setCompletionBlock { [weak self, weak label] in
                    guard let self, let label, self.generation == token,
                          self.currentRank != key, self.labels[key] === label else { return }
                    label.removeFromSuperview()
                    self.labels.removeValue(forKey: key)
                }
            }
            let movement = CABasicAnimation(keyPath: "transform.translation.y")
            movement.fromValue = startY; movement.toValue = endY
            movement.duration = entering ? 0.22 : 0.19
            movement.timingFunction = curve
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = startAlpha; fade.toValue = endAlpha
            fade.duration = entering ? 0.15 : 0.12
            fade.beginTime = entering ? 0.035 : 0
            fade.fillMode = .both
            fade.timingFunction = curve
            let group = CAAnimationGroup()
            group.animations = [movement, fade]
            group.duration = movement.duration
            label.layer.add(group, forKey: "button-state-text")
            CATransaction.commit()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Layer transforms carry the rolling offset independently of layout.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for label in labels.values {
            label.bounds = CGRect(origin: .zero, size: bounds.size)
            label.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }

    func settle() {
        generation &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (rank, label) in labels {
            label.layer.removeAllAnimations()
            if rank == currentRank {
                label.layer.opacity = 1
                label.layer.transform = CATransform3DIdentity
            } else {
                label.removeFromSuperview()
            }
        }
        labels = labels.filter { $0.key == currentRank }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { settle() }
    }
}
