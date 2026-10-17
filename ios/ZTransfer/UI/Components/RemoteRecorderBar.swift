import SwiftUI
import UIKit

enum RemoteRecorderAction: Equatable {
    case start, stop, lockedHint, none
    static func resolve(phase: RemoteLocalRecordingPhase, enabled: Bool) -> Self {
        switch phase {
        case .finalizing, .saved: .none
        case .recording, .paused: .stop
        case .idle: enabled ? .start : .lockedHint
        }
    }
}

@MainActor
final class RemoteRecorderController: NSObject, ObservableObject {
    @Published private(set) var motion: RemoteRecorderMotion
    private var link: CADisplayLink?
    private var hintTask: Task<Void, Never>?
    private let density: Float
    init(_ configuration: RemoteRecorderMotion.Configuration, density: Float) {
        self.density = density
        motion = .init(configuration, density: density)
    }
    func configure(_ next: RemoteRecorderMotion.Configuration) { motion.configure(next); schedule() }
    func showLockedHint() {
        hintTask?.cancel()
        motion.showLockedHint(true); schedule()
        hintTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1800)) } catch { return }
            guard let self else { return }
            motion.showLockedHint(false); schedule(); hintTask = nil
        }
    }
    private func schedule() {
        guard motion.needsFrames, link == nil else { return }
        let next = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link = next; next.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ sender: CADisplayLink) {
        motion.advance(Int64(sender.timestamp * 1_000_000_000))
        if !motion.needsFrames { link?.invalidate(); link = nil }
    }
    func stop() {
        link?.invalidate(); link = nil; hintTask?.cancel(); hintTask = nil
        motion = .init(motion.configuration, density: density)
    }
}

/// The production RecControlBar state/labels/actions are identical in both
/// orientations; only the saved label's compactness changes in landscape.
struct RemoteRecorderBar: View {
    let phase: RemoteLocalRecordingPhase
    let elapsedSeconds: Int
    let enabled: Bool
    let compactSaved: Bool
    let onStart: () -> Void
    let onPauseResume: () -> Void
    let onStop: () -> Void
    @Environment(\.displayScale) private var density
    var body: some View {
        RemoteRecorderContent(configuration: .init(phase: phase, compactSaved: compactSaved),
            elapsedSeconds: elapsedSeconds, enabled: enabled, density: density,
            onStart: onStart, onPauseResume: onPauseResume, onStop: onStop)
    }
}

private struct RemoteRecorderContent: View {
    let configuration: RemoteRecorderMotion.Configuration
    let elapsedSeconds: Int
    let enabled: Bool
    let density: CGFloat
    let onStart: () -> Void
    let onPauseResume: () -> Void
    let onStop: () -> Void
    @StateObject private var controller: RemoteRecorderController
    @Environment(\.colorScheme) private var colorScheme
    init(configuration: RemoteRecorderMotion.Configuration, elapsedSeconds: Int, enabled: Bool,
         density: CGFloat, onStart: @escaping () -> Void, onPauseResume: @escaping () -> Void,
         onStop: @escaping () -> Void) {
        self.configuration = configuration; self.elapsedSeconds = elapsedSeconds
        self.enabled = enabled; self.density = density
        self.onStart = onStart; self.onPauseResume = onPauseResume; self.onStop = onStop
        _controller = StateObject(wrappedValue: RemoteRecorderController(configuration, density: Float(density)))
    }
    private var dark: Bool { colorScheme == .dark }
    private var heavyBase: Color { dark ? Color(white: 30 / 255) : .white }
    private var panelBorder: Color { dark ? .white.opacity(0.15) : .black.opacity(0.10) }
    private var motion: RemoteRecorderMotion { controller.motion }
    private var startDescription: String {
        AppLocalized.resource(configuration.saved ? "cd_remote_rec_saved"
            : configuration.recording ? "cd_remote_rec_stop" : "cd_remote_rec_start")
    }
    var body: some View {
        ZStack(alignment: .leading) {
            RemoteRecorderPanel(dark: dark)
            ZStack(alignment: .leading) {
                startButton.offset(x: 4)
                if motion.pauseAlpha.value > 0.01 {
                    pauseButton.offset(x: 38)
                }
                if motion.savedLabel.retained {
                    Text(AppLocalized.resource("remote_rec_saved_label"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ZTransferColors.statusConnected)
                        .frame(height: 12).fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .opacity(Double(motion.savedLabel.alpha.value))
                        .scaleEffect(CGFloat(motion.savedLabel.scale.value), anchor: .leading)
                        .offset(x: 37)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .opacity(enabled ? 1 : 0.4)
        }
        .frame(width: CGFloat(motion.surfaceWidth.value), height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .circular))
        .frame(width: CGFloat(motion.layoutWidth.value), alignment: .leading)
        .overlay(alignment: .topLeading) {
            if motion.timer.retained {
                timerBubble
                    .opacity(Double(motion.timer.alpha.value))
                    .scaleEffect(CGFloat(motion.timer.scale.value), anchor: .bottom)
                    .offset(y: CGFloat(floor(motion.timer.slide.value + 0.5)) / density)
                    // Compose EnterExitTransition clips only size-changing
                    // transitions; this fade/scale/slide must remain unbounded.
                    .frame(height: 18)
                    .offset(y: -23)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if motion.lockedHint.retained {
                Text(AppLocalized.resource("remote_rec_pro_only"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ZTransferColors.primaryText)
                    .frame(height: 16).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(heavyBase.opacity(dark ? 0.92 : 0.95), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(panelBorder, lineWidth: 1))
                    .fixedSize()
                    .opacity(Double(motion.lockedHint.alpha.value))
                    .scaleEffect(CGFloat(motion.lockedHint.scale.value), anchor: .bottom)
                    .offset(y: -38)
                    .accessibilityIdentifier("remote-record-locked-hint")
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { controller.configure(configuration) }
        .onChange(of: configuration) { controller.configure($0) }
        .onDisappear { controller.stop() }
    }
    private var startButton: some View {
        Button {
            switch RemoteRecorderAction.resolve(phase: configuration.phase, enabled: enabled) {
            case .start: onStart()
            case .stop: onStop()
            case .lockedHint: controller.showLockedHint()
            case .none: break
            }
        } label: {
            ZStack {
                ForEach([false, true].filter { motion.icons[$0] != nil }, id: \.self) { saved in
                    if let icon = motion.icons[saved] {
                        RemoteRecorderIcon(saved: saved,
                            stopping: configuration.recording || configuration.phase == .finalizing)
                            .frame(width: 14, height: 14)
                            .opacity(Double(icon.alpha.value)).scaleEffect(CGFloat(icon.scale.value))
                    }
                }
            }.frame(width: 28, height: 28)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14, active: configuration.saved,
            activeColor: ZTransferColors.statusConnected, showSheen: false, shadowElevation: 0))
        .accessibilityLabel(startDescription).accessibilityIdentifier("remote-record-start-stop")
    }
    private var pauseButton: some View {
        Button(action: onPauseResume) {
            RemoteRecorderPauseIcon(paused: configuration.phase == .paused)
                .frame(width: 14, height: 14).frame(width: 28, height: 28)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14, showSheen: false, shadowElevation: 0))
        .disabled(!configuration.recording)
        .opacity(Double(motion.pauseAlpha.value))
        .scaleEffect(CGFloat(0.7 + 0.3 * motion.pauseAlpha.value))
        .accessibilityLabel(AppLocalized.resource(configuration.phase == .paused ? "cd_remote_rec_resume" : "cd_remote_rec_pause"))
        .accessibilityIdentifier("remote-record-pause-resume")
    }
    private var timerBubble: some View {
        HStack(spacing: 0) {
            Text("●").font(.system(size: 8)).frame(height: 10).foregroundStyle(ZTransferColors.statusError)
            Text(String(format: " %d:%02d", elapsedSeconds / 60, elapsedSeconds % 60))
                .font(.system(size: 10, weight: .medium, design: .monospaced)).frame(height: 12)
                .foregroundStyle(ZTransferColors.primaryText)
                .accessibilityIdentifier("remote-record-elapsed")
        }.padding(.horizontal, 8).padding(.vertical, 3)
            .background(heavyBase.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((dark ? Color.white : .black).opacity(0.65), lineWidth: 0.5))
            .fixedSize()
    }
}

private struct RemoteRecorderIcon: View {
    let saved: Bool
    let stopping: Bool
    var body: some View {
        Canvas { context, size in
            if saved {
                var path = Path()
                path.move(to: CGPoint(x: size.width * 0.2, y: size.height * 0.55))
                path.addLine(to: CGPoint(x: size.width * 0.4, y: size.height * 0.8))
                path.addLine(to: CGPoint(x: size.width * 0.8, y: size.height * 0.25))
                context.stroke(path, with: .color(ZTransferColors.statusConnected),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else if stopping {
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.14, dy: size.height * 0.14)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ZTransferColors.statusError))
            } else {
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(ZTransferColors.statusError))
            }
        }.accessibilityHidden(true)
    }
}

private struct RemoteRecorderPauseIcon: View {
    let paused: Bool
    var body: some View {
        Canvas { context, size in
            var path = Path()
            if paused {
                let margin = min(size.width, size.height) * 0.18
                path.move(to: CGPoint(x: margin + 1, y: margin))
                path.addLine(to: CGPoint(x: size.width - margin, y: size.height / 2))
                path.addLine(to: CGPoint(x: margin + 1, y: size.height - margin)); path.closeSubpath()
            } else {
                let width = size.width * 0.26, x = size.width * 0.16, y = size.height * 0.14
                for left in [x, size.width - x - width] {
                    path.addRoundedRect(in: CGRect(x: left, y: y, width: width, height: size.height - 2 * y),
                                        cornerSize: CGSize(width: width / 2, height: width / 2))
                }
            }
            context.fill(path, with: .color(ZTransferColors.primaryText))
        }.accessibilityHidden(true)
    }
}

/// GlassSurface(panel=true,borderColor=Transparent), which remains a glass
/// panel even when its child buttons use a physical skin. GlassButton.kt's
/// liquidGlassOptics has distinct optics from the frosted button material.
private struct RemoteRecorderPanel: View {
    let dark: Bool
    var body: some View {
        Canvas { context, size in
            let path = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 18)
            let longest = max(size.width, size.height)
            context.fill(path, with: .color(ZTransferColors.primaryText.opacity(0.05)))
            context.fill(path, with: .linearGradient(Gradient(colors: [.white.opacity(dark ? 0.08 : 0.55), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let ambient = 0.15 * 0.68
            context.fill(path, with: .radialGradient(Gradient(colors: [.white.opacity(ambient), .white.opacity(ambient * 0.28), .clear]),
                center: CGPoint(x: size.width * 0.10, y: size.height * 0.03), startRadius: 0, endRadius: longest * 0.92))
            let depth = dark ? Color.black : Color(red: 109 / 255, green: 125 / 255, blue: 141 / 255)
            context.fill(path, with: .radialGradient(Gradient(colors: [depth.opacity((dark ? 0.12 : 0.075) * 0.68), .clear]),
                center: CGPoint(x: size.width * 1.04, y: size.height * 1.06), startRadius: 0, endRadius: longest * 0.88))
            let band = Gradient(stops: [
                .init(color: .clear, location: 0), .init(color: .clear, location: 0.36),
                .init(color: Color(red: 189 / 255, green: 239 / 255, blue: 1).opacity(0.055 * 0.46), location: 0.455),
                .init(color: .white.opacity(0.055), location: 0.505),
                .init(color: Color(red: 1, green: 217 / 255, blue: 242 / 255).opacity(0.055 * 0.34), location: 0.555),
                .init(color: .clear, location: 0.66), .init(color: .clear, location: 1)])
            context.fill(path, with: .linearGradient(band,
                startPoint: CGPoint(x: -size.width * 0.72, y: -size.height * 0.10),
                endPoint: CGPoint(x: size.width * 0.92, y: size.height * 1.12)))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
