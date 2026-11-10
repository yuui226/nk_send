import SwiftUI
import UIKit

/// RemoteSelfTimerUi.kt: same anchored choice popup in either orientation.
struct RemoteSelfTimerPanel: View {
    let selected: Int
    let anchor: CGRect?
    let hostSize: CGSize
    let landscape: Bool
    let closing: Bool
    let select: (Int) -> Void
    let close: () -> Void
    let dismiss: () -> Void

    static func label(_ seconds: Int) -> String {
        seconds == 0 ? AppLocalized.resource("setting_off")
            : String(format: AppLocalized.resource("remote_self_timer_seconds"), seconds)
    }
    private var width: CGFloat {
        let measured = RemoteSelfTimer.options.map {
            (Self.label($0) as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14)]).width
        }.max() ?? 0
        return min(240, max(80, ceil(measured) + 24))
    }
    var body: some View {
        RemoteChoicePopup(anchor: anchor, hostSize: hostSize, landscape: landscape,
            width: width, contentHeight: CGFloat(RemoteSelfTimer.options.count) * 36,
            closing: closing, trigger: .remoteSelfTimer, accessibilityID: "remote-self-timer-backdrop",
            close: close, dismiss: dismiss) { placement in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(RemoteSelfTimer.options, id: \.self) { seconds in
                            Button {
                                ZTransferHaptics.shared.play(.selection)
                                select(seconds); close()
                            } label: {
                                Text(Self.label(seconds)).font(.system(size: 14))
                                    .foregroundStyle(selected == seconds ? ZTransferColors.accentBlue : ZTransferColors.primaryText)
                                    .lineLimit(1).frame(maxWidth: .infinity, minHeight: 20)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background {
                                        // Explicit rectangle avoids inheriting the popup's
                                        // rounded container shape for an interior selection.
                                        Rectangle().fill(selected == seconds ? ZTransferColors.accentBlue.opacity(0.08) : .clear)
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(closing)
                            .accessibilityIdentifier("remote-self-timer-choice-\(seconds)")
                            .accessibilityAddTraits(selected == seconds ? .isSelected : [])
                        }
                    }
                }
                .frame(height: min(CGFloat(RemoteSelfTimer.options.count) * 36, placement.availableHeight))
                .background(ZTransferColors.surface, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
    }
}

struct RemoteSelfTimerIcon: View {
    var seconds = 0
    var body: some View {
        if seconds > 0 {
            Text(RemoteSelfTimerPanel.label(seconds)).font(.system(size: 10, weight: .bold)).lineLimit(1)
        } else {
            Canvas { context, size in
                let scale = size.width / 19
                context.scaleBy(x: scale, y: scale)
                var path = Path()
                path.addEllipse(in: CGRect(x: 3.2, y: 4.4, width: 12.6, height: 12.6))
                for (a, b) in [(CGPoint(x: 7.4, y: 1.5), CGPoint(x: 11.6, y: 1.5)),
                               (CGPoint(x: 9.5, y: 1.5), CGPoint(x: 9.5, y: 3.3)),
                               (CGPoint(x: 14.6, y: 5.6), CGPoint(x: 16.1, y: 4.1)),
                               (CGPoint(x: 9.5, y: 10.7), CGPoint(x: 9.5, y: 6.9))] {
                    path.move(to: a); path.addLine(to: b)
                }
                context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }.frame(width: 19, height: 19)
        }
    }
}

/// Only this leaf observes countdown ticks; the monitor/frame tree does not.
struct RemoteSelfTimerShutter: View {
    @ObservedObject var timer: RemoteSelfTimer
    let capture: RemoteCapturePhase
    let movieMode: Bool
    let enabled: Bool
    let focusing: Bool
    let delaySeconds: Int
    let onQuickTap: () -> Void
    let onFocusStart: () -> Void
    let onRelease: (Bool) -> Void
    let onCancel: () -> Void
    let diameter: CGFloat
    var body: some View {
        RemoteShutterButton(capture: capture, movieMode: movieMode, enabled: enabled, focusing: focusing,
            onQuickTap: onQuickTap, onFocusStart: onFocusStart, onRelease: onRelease, diameter: diameter,
            delaySeconds: delaySeconds, timerActive: timer.active, remainingSeconds: timer.remainingSeconds,
            timerFocusing: timer.focusing, onCancel: onCancel)
    }
}
