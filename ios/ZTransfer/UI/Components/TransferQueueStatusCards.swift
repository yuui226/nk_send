import SwiftUI
import UIKit

/// TransferQueueStatusGroup geometry, independent of task/count changes.
struct QueueSummaryGeometry: Equatable {
    let padding: CGFloat
    let header: CGFloat
    let row: CGFloat
    let body: CGFloat
    let height: CGFloat
    let stackedTime: Bool
    init(width: CGFloat, compact: Bool, fontScale: CGFloat = 1) {
        padding = width < 340 || compact ? 8 : 10
        let generationWidth = (width - 8) * 0.45 - 2 * padding
        stackedTime = generationWidth - 38 * fontScale - 4 < 76 * fontScale
        let detail = max(14 * fontScale, 16) + 4
        header = max(20 * fontScale + 4, 16 * fontScale, detail)
        row = stackedTime ? header + 2 + detail : header
        body = row * 2 + 6
        height = padding * 2 + body
    }
}

struct TransferQueueStatusGroup: View {
    let presentation: TransferQueuePresentation
    let tasks: [TransferQueueItem]
    let progress: TransferQueueProgressViewModel
    let width: CGFloat
    let compact: Bool
    private var geometry: QueueSummaryGeometry { .init(width: width, compact: compact) }
    var body: some View {
        #if DEBUG
        let _ = QueueSummaryRenderProbe.onRender?("group")
        #endif
        HStack(spacing: 8) {
            QueueDownloadStatusCard(presentation: presentation, tasks: tasks, progressModel: progress, geometry: geometry)
                .frame(width: max(0, width - 8) * 0.55)
            QueueGenerationStatusCard(tasks: presentation.generationTasks, history: tasks,
                state: presentation.generationState, count: presentation.generationRemaining, geometry: geometry)
                .frame(width: max(0, width - 8) * 0.45)
        }
        .frame(height: geometry.height)
        .accessibilityIdentifier("queue_status_group")
    }
}

#if DEBUG
@MainActor enum QueueSummaryRenderProbe {
    static var onRender: ((String) -> Void)?
}
#endif

private struct QueueDownloadStatusCard: View {
    let presentation: TransferQueuePresentation
    let tasks: [TransferQueueItem]
    @ObservedObject var progressModel: TransferQueueProgressViewModel
    let geometry: QueueSummaryGeometry
    @StateObject private var display: QueueDownloadDisplayModel
    @State private var retained: TransferQueueItem?
    @State private var retainedSpeed: Int64?
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase
    init(presentation: TransferQueuePresentation, tasks: [TransferQueueItem],
         progressModel: TransferQueueProgressViewModel, geometry: QueueSummaryGeometry) {
        self.presentation = presentation; self.tasks = tasks; self.progressModel = progressModel; self.geometry = geometry
        _display = StateObject(wrappedValue: .init(initialTask: presentation.downloadTask))
        _retained = State(initialValue: presentation.downloadTask)
        _retainedSpeed = State(initialValue: queueSummarySpeed(displayed: presentation.downloadTask, completed: nil,
            progress: progressModel.activeProgress, state: presentation.downloadState))
    }
    private var speed: Int64? {
        queueSummarySpeed(displayed: display.task,
            completed: display.completing ? display.task : queueDownloadCompletedTask(display.task?.id, active: presentation.downloadTask, tasks: tasks),
            progress: progressModel.activeProgress, state: presentation.downloadState)
    }
    private struct Input: Equatable {
        let task: TransferQueueItem?
        let progress: TransferActiveProgress?
        let animate: Bool
        let history: [TransferQueueItem]
    }
    private var input: Input {
        .init(task: presentation.downloadTask, progress: progressModel.activeProgress,
              animate: visible && scenePhase == .active, history: tasks)
    }
    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                QueueSummaryPresence(visible: display.task == nil, enter: 160) {
                    QueueSummaryStateIcon(state: presentation.downloadState, generation: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                QueueSummaryPresence(visible: display.task != nil, enter: 160) {
                    if let task = display.task ?? retained {
                        VStack(alignment: .leading, spacing: 0) {
                            QueueSummaryFilename(task: task).frame(height: geometry.header)
                            Spacer(minLength: 0)
                            HStack(spacing: 5) {
                                TransferInfoPill(text: TransferQueueCardText(item: task).fileSizeText(),
                                    color: ZTransferColors.secondaryText, compact: true)
                                    .accessibilityIdentifier("queue_download_size")
                                QueueSummaryPresence(visible: speed != nil, enter: 140) {
                                    if let sample = speed ?? retainedSpeed {
                                        TransferInfoPill(text: transferSpeedText(sample), color: ZTransferColors.statusConnected,
                                            numericValue: sample, compact: true)
                                            .fixedSize().accessibilityIdentifier("queue_download_speed")
                                    }
                                }.layoutPriority(1)
                            }.frame(height: geometry.header)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            QueueSummaryRemainingBadge(count: presentation.downloadRemaining, generation: false)
        }
        .padding(geometry.padding)
        .background {
            QueueSummarySurface(generation: false, running: display.task != nil, active: visible && scenePhase == .active)
            QueueSummaryProgress(value: display.progress, taskID: display.task?.id)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .modifier(QueueSummaryBorder())
        .accessibilityIdentifier("queue_download_summary")
        .onAppear { visible = true; update(input) }
        .onDisappear {
            visible = false
            display.update(active: presentation.downloadTask, progress: progressModel.activeProgress, tasks: tasks, animate: false)
            display.stop()
        }
        .onChange(of: input) { update($0) }
        .onChange(of: display.task) { if let task = $0 { retained = task } }
        .onChange(of: speed) { if let speed = $0 { retainedSpeed = speed } }
    }
    private func update(_ next: Input) {
        display.update(active: next.task, progress: next.progress, tasks: next.history, animate: next.animate)
    }
}

private struct QueueSummaryProgress: View {
    @ObservedObject var value: AndroidAnimatedOpacity
    let taskID: UUID?
    var body: some View {
        if let taskID {
            LiquidTransferProgressSurface(progress: Double(value.value), seed: taskID.uuidString)
                .opacity(0.10 / 0.14)
                .accessibilityValue("\(Int(value.value * 100))%")
        }
    }
}

private struct QueueGenerationStatusCard: View {
    let tasks: [TransferQueueItem]
    let history: [TransferQueueItem]
    let state: QueueActivityState
    let count: Int
    let geometry: QueueSummaryGeometry
    @StateObject private var model = GenerationRowsModel()
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase
    private struct Input: Equatable {
        let tasks: [TransferQueueItem]
        let history: [TransferQueueItem]
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            QueueSummaryPresence(visible: model.rows.isEmpty, enter: 160) {
                QueueSummaryStateIcon(state: .idle, generation: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.rows.isEmpty {
                HStack(spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        ForEach(model.rows) { row in
                            QueueGenerationAnimatedRow(row: row, geometry: geometry, active: visible && scenePhase == .active) {
                                model.finish(id: row.id, phase: $0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: geometry.body, alignment: .topLeading).clipped()
                    QueueGenerationRemainingBadge(count: count)
                }
            }
        }
        .frame(height: geometry.body, alignment: .topLeading)
        .padding(geometry.padding)
        .background { QueueSummarySurface(generation: true, running: state == .running, active: visible && scenePhase == .active) }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .modifier(QueueSummaryBorder())
        .accessibilityIdentifier("queue_generation_summary")
        .onAppear { visible = true; model.update(tasks: tasks, history: history) }
        .onChange(of: Input(tasks: tasks, history: history)) { model.update(tasks: $0.tasks, history: $0.history) }
        .onDisappear { visible = false; model.reset() }
    }
}

/// Android dfd66a20: hold the last positive badge's layout until its rows have
/// departed. Zero is neither drawn nor announced, and idle owns the full width.
private struct QueueGenerationRemainingBadge: View {
    let count: Int
    @State private var lastPositive: Int
    @State private var opacity: QueueGenerationBadgeOpacity
    init(count: Int) {
        self.count = count
        _lastPositive = State(initialValue: max(0, count))
        _opacity = State(initialValue: .init(visible: count > 0))
    }
    var body: some View {
        QueueSummaryRemainingBadge(count: count > 0 ? count : lastPositive, generation: true)
            .modifier(AndroidOpacity(opacity: opacity.value))
            .accessibilityHidden(count <= 0)
            .onChange(of: count) { next in
                if next > 0 { lastPositive = next }
                opacity.update(visible: next > 0)
            }
            .onDisappear { opacity.stop() }
    }
}

@MainActor private final class QueueGenerationBadgeOpacity {
    let value = AndroidAnimatedOpacity()
    private var animation: ZTransferScalarAnimation
    private var link: CADisplayLink?
    init(visible: Bool) {
        animation = .init(value: visible ? 1 : 0)
        value.update(animation.value)
    }
    func update(visible: Bool) {
        animation.retarget(visible ? 1 : 0, using: .tween(milliseconds: 120))
        guard animation.isRunning, link == nil else { return }
        link = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.animation.advance(frameNanos: Int64(frame.timestamp * 1_000_000_000))
            owner.value.update(owner.animation.value)
            if !owner.animation.isRunning { owner.stop() }
        }
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
}

private struct QueueGenerationAnimatedRow: View {
    let row: GenerationRowSnapshot
    let geometry: QueueSummaryGeometry
    let active: Bool
    let onFinish: (GenerationRowPhase) -> Void
    @StateObject private var animator: GenerationRowAnimator
    private struct Input: Equatable {
        let position: Int
        let height: CGFloat
        let phase: GenerationRowPhase
        let active: Bool
    }
    private var input: Input { .init(position: row.position, height: geometry.row, phase: row.phase, active: active) }
    init(row: GenerationRowSnapshot, geometry: QueueSummaryGeometry, active: Bool, onFinish: @escaping (GenerationRowPhase) -> Void) {
        self.row = row; self.geometry = geometry; self.active = active; self.onFinish = onFinish
        _animator = StateObject(wrappedValue: .init(position: row.position, height: geometry.row))
    }
    var body: some View {
        QueueGenerationRowFrame(animator: animator, row: row, geometry: geometry, active: active)
            .accessibilityHidden(row.phase.retiring || row.position >= 2)
            .accessibilityIdentifier("queue_generation_task_\(row.id)")
            .onAppear { update(input) }
            .onChange(of: input) { update($0) }
            .onDisappear { animator.onFinish = nil; animator.stop() }
    }
    private func update(_ next: Input) {
        animator.onFinish = onFinish
        if next.active { animator.update(position: next.position, height: next.height, phase: next.phase) }
        else { animator.stop() }
    }
}

private struct QueueGenerationRowFrame: View {
    @ObservedObject var animator: GenerationRowAnimator
    let row: GenerationRowSnapshot
    let geometry: QueueSummaryGeometry
    let active: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let color = ZTransferColors.primaryText.mix(with: ZTransferColors.statusConnected, by: Double(animator.motion.success.value), scheme: scheme)
        Group {
            if geometry.stackedTime {
                VStack(alignment: .leading, spacing: 2) {
                    QueueSummaryFilename(task: row.task, includeExtension: false, color: color).frame(height: geometry.header)
                    QueueSummaryGenerationTime(task: row.task, phase: row.phase, active: active)
                }
            } else {
                HStack(spacing: 4) {
                    QueueSummaryFilename(task: row.task, includeExtension: false, color: color)
                    QueueSummaryGenerationTime(task: row.task, phase: row.phase, active: active).fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: geometry.row, alignment: geometry.stackedTime ? .topLeading : .leading)
        .offset(y: CGFloat(animator.motion.top.value))
        .opacity(Double(animator.motion.alpha.value))
        .transaction { $0.animation = nil }
    }
}

private struct QueueSummaryGenerationTime: View {
    let task: TransferQueueItem
    let phase: GenerationRowPhase
    let active: Bool
    @State private var lastElapsed: Int64?
    var body: some View {
        Group {
            if active && !phase.frozen && task.frameGenerationStartedAtElapsedMs != nil {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let elapsed = task.displayedFrameGenerationElapsedMs(now: PhotoGenerationClock.now())
                    label(elapsed).onAppear { lastElapsed = elapsed }.onChange(of: elapsed) { lastElapsed = $0 }
                }
            } else { label(phase.frozen ? (task.frameGenerationElapsedMs ?? lastElapsed) : nil) }
        }
    }
    private func label(_ elapsed: Int64?) -> some View {
        TransferInfoPill(text: elapsed.map(queueSummaryDuration) ?? "", color: ZTransferColors.accentPurple,
                         waiting: elapsed == nil, compact: true, allowsTruncation: false)
    }
}

func queueSummaryDuration(_ milliseconds: Int64) -> String {
    let value = max(0, milliseconds)
    return value < 60_000 ? String(format: "%.1fs", Double(value) / 1000) : String(format: "%dm%02ds", value / 60_000, value % 60_000 / 1000)
}

private struct QueueSummaryFilename: View {
    let task: TransferQueueItem
    var includeExtension = true
    var color: Color?
    @StateObject private var clock = QueueSummaryFilenameClock()
    var body: some View {
        TransferFileTitle(name: includeExtension ? task.file.fileName : (task.file.fileName as NSString).deletingPathExtension,
                          cancelled: false, style: .labelMedium, color: color, accessibilityName: task.file.fileName)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(task.file.fileName)
            .modifier(AndroidOpacity(opacity: clock.opacity))
            .onAppear { clock.update(task.id) }
            .onChange(of: task.id) { clock.update($0) }
            .onDisappear { clock.stop() }
    }
}

@MainActor private final class QueueSummaryFilenameClock: ObservableObject {
    let opacity = AndroidAnimatedOpacity()
    private var id: UUID?
    private var animation = ZTransferScalarAnimation(value: 1)
    private var link: CADisplayLink?
    init() { opacity.update(1) }
    func update(_ id: UUID) {
        guard self.id != id else { return }
        let previous = self.id; self.id = id
        guard previous != nil else { return }
        stop(); animation.reset(to: 0.72); opacity.update(0.72)
        animation.retarget(1, using: .tween(milliseconds: 160))
        link = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.animation.advance(frameNanos: Int64(frame.timestamp * 1_000_000_000))
            owner.opacity.update(owner.animation.value)
            if !owner.animation.isRunning { owner.stop() }
        }
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
}

private struct QueueSummaryStateIcon: View {
    let state: QueueActivityState
    let generation: Bool
    var body: some View {
        Group {
            if state == .paused { QueueTopIcon(kind: .pause).fill(ZTransferColors.secondaryText) }
            else { QueueBadgeIcon(state: state == .waiting ? .waiting : (generation ? .generating : .transferring)).fill(ZTransferColors.secondaryText) }
        }
        .frame(width: 24, height: 24)
        .foregroundStyle(ZTransferColors.secondaryText)
        .opacity(state == .idle ? 0.48 : 0.76)
        .accessibilityLabel(AppLocalized.resource(state == .paused ? "queue_summary_paused" : (state == .waiting ? "queue_focus_waiting_transfer" : "queue_summary_idle")))
    }
}

private struct QueueSummaryRemainingBadge: View {
    let count: Int
    let generation: Bool
    @StateObject private var clock = QueuePillWidthClock()
    @Environment(\.displayScale) private var scale
    private func width(_ count: Int) -> CGFloat {
        max(26, ceil(("\(count)" as NSString).size(withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)]).width) + 12)
    }
    var body: some View {
        if count > 0 {
            QueueSummaryBadgeFrame(clock: clock, width: width(count), color: generation ? ZTransferColors.accentPurple : ZTransferColors.accentBlue) {
                QueuePillRollingCount(count: count, color: generation ? ZTransferColors.accentPurple : ZTransferColors.accentBlue)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppLocalized.formattedResource(generation ? "queue_summary_generation_remaining" : "queue_summary_download_remaining", ["%1$d": "\(count)"]))
            .accessibilityIdentifier(generation ? "queue_generation_count" : "queue_download_count")
            .onAppear { clock.update(width: width(count), scale: scale) }
            .onChange(of: count) { clock.update(width: width($0), scale: scale) }
            .onChange(of: scale) { clock.update(width: width(count), scale: $0) }
            .onDisappear { clock.reset() }
        }
    }
}

private struct QueueSummaryBadgeFrame<Content: View>: View {
    @ObservedObject var clock: QueuePillWidthClock
    let width: CGFloat
    let color: Color
    @ViewBuilder let content: Content
    var body: some View {
        content.frame(width: clock.motion.width ?? width, height: 24)
            .background(color.opacity(0.09), in: Capsule()).clipShape(Capsule())
            .transaction { $0.animation = nil }
    }
}

private struct QueueSummaryBorder: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(LinearGradient(colors: [
                .white.opacity(0.32), scheme == .dark ? .clear : .black.opacity(0.06), .black.opacity(0.08)
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }.background { AndroidShadowView(cornerRadius: 16, elevation: 6, shadowColors: .init(ambientAlpha: 20, spotAlpha: 31)) }
    }
}

/// Only backing layers animate activity and the 2.4s ambient fill; no layout,
/// text, timer or camera work is driven by this indefinitely repeating motion.
private struct QueueSummarySurface: UIViewRepresentable {
    let generation: Bool
    let running: Bool
    let active: Bool
    func makeUIView(context: Context) -> QueueSummarySurfaceView { QueueSummarySurfaceView() }
    func updateUIView(_ view: QueueSummarySurfaceView, context: Context) {
        let traits = UITraitCollection(userInterfaceStyle: context.environment.colorScheme == .dark ? .dark : .light)
        view.update(base: UIColor(ZTransferColors.surface).resolvedColor(with: traits),
            accent: UIColor(generation ? ZTransferColors.accentPurple : ZTransferColors.accentBlue).resolvedColor(with: traits),
            running: running, breathe: generation && active, dark: context.environment.colorScheme == .dark)
    }
}

final class QueueSummarySurfaceView: UIView {
    private let tint = CALayer(), sheen = CAGradientLayer(), presence = CALayer(), pulse = CALayer()
    private var running: Bool?
    private var breathing = false
    private var requestedBreathe = false
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false
        layer.addSublayer(tint); layer.addSublayer(sheen); layer.addSublayer(presence); presence.addSublayer(pulse)
        sheen.colors = [UIColor.white.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
        presence.opacity = 0; pulse.opacity = 0
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for item in [tint, sheen, presence, pulse] { item.frame = bounds }
        CATransaction.commit()
    }
    func update(base: UIColor, accent: UIColor, running: Bool, breathe: Bool, dark: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backgroundColor = base; tint.backgroundColor = accent.cgColor; pulse.backgroundColor = accent.cgColor
        sheen.colors = [UIColor.white.withAlphaComponent(dark ? 0.08 : 0.10).cgColor, UIColor.clear.cgColor]
        CATransaction.commit()
        if self.running != running {
            animate(tint, to: running ? 0.09 : 0.035, initial: self.running == nil)
            self.running = running
        }
        requestedBreathe = running && breathe
        updateBreathing()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { pulse.removeAnimation(forKey: "breathe"); breathing = false }
        else { updateBreathing() }
    }
    private func updateBreathing() {
        let next = requestedBreathe && window != nil
        guard breathing != next else { return }
        breathing = next
        animate(presence, to: next ? 1 : 0, initial: false)
        if next {
            if pulse.animation(forKey: "breathe") == nil {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 0; animation.toValue = 0.08; animation.duration = 2.4
                animation.autoreverses = true; animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                pulse.add(animation, forKey: "breathe")
            }
        } else {
            // Retire the ambient cycle only after its 220ms presence fade.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, !breathing else { return }
                pulse.removeAnimation(forKey: "breathe")
            }
        }
    }
    private func animate(_ layer: CALayer, to: Float, initial: Bool) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.opacity = to; CATransaction.commit()
        guard !initial else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to; animation.duration = 0.22
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        layer.add(animation, forKey: "activity")
    }
}

private struct QueueSummaryPresence<Content: View>: View {
    let visible: Bool
    let enter: Int64
    @ViewBuilder let content: Content
    @StateObject private var clock: QueueSummaryPresenceClock
    init(visible: Bool, enter: Int64, @ViewBuilder content: () -> Content) {
        self.visible = visible; self.enter = enter; self.content = content()
        _clock = StateObject(wrappedValue: .init(visible: visible, enter: enter))
    }
    var body: some View {
        Group {
            if visible || clock.retained { content.modifier(AndroidOpacity(opacity: clock.opacity)).accessibilityHidden(!visible) }
        }
        .onAppear { clock.update(visible) }
        .onChange(of: visible) { clock.update($0) }
        .onDisappear { clock.stop() }
    }
}

@MainActor private final class QueueSummaryPresenceClock: ObservableObject {
    @Published private(set) var retained: Bool
    let opacity = AndroidAnimatedOpacity()
    private var fade: QueuePillFadeMotion
    private var link: CADisplayLink?
    init(visible: Bool, enter: Int64) {
        retained = visible
        fade = .init(initiallyVisible: visible, enterMilliseconds: enter, enterDelayMilliseconds: 0, exitMilliseconds: 100)
        opacity.update(fade.alpha.value)
    }
    func update(_ visible: Bool) {
        if !visible && fade.phase == .preEnter { return }
        if visible { retained = true }
        fade.setVisible(visible)
        guard fade.alpha.isRunning, link == nil else { return }
        link = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.fade.advance(Int64(frame.timestamp * 1_000_000_000)); owner.opacity.update(owner.fade.alpha.value)
            if owner.fade.exitFinished { owner.retained = false }
            if !owner.fade.alpha.isRunning { owner.stop() }
        }
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
}
