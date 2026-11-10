import SwiftUI
import UIKit

func queueDownloadActiveTask(_ task: TransferQueueItem?) -> TransferQueueItem? {
    guard let task, task.status == .transferring, !task.isGeneratingFrame else { return nil }
    return task
}

func queueDownloadTargetProgress(_ task: TransferQueueItem?, _ progress: TransferActiveProgress?) -> Float {
    guard let task = queueDownloadActiveTask(task) else { return 0 }
    let value = progress?.taskID == task.id ? progress!.fraction : task.progress
    return value.isFinite ? Float(min(max(value, 0), 1)) : 0
}

func queueDownloadCompletedTask(_ id: UUID?, active: TransferQueueItem?, tasks: [TransferQueueItem]) -> TransferQueueItem? {
    guard let id, id != queueDownloadActiveTask(active)?.id,
          let task = tasks.first(where: { $0.id == id }),
          task.status == .completed || (task.status == .transferring && task.isGeneratingFrame) else { return nil }
    return task
}

func queueSummarySpeed(displayed: TransferQueueItem?, completed: TransferQueueItem?,
                       progress: TransferActiveProgress?, state: QueueActivityState) -> Int64? {
    if let completed {
        let bytes = completed.downloadMBps * 1024 * 1024
        if bytes.isFinite, bytes >= 1 { return bytes >= Double(Int64.max) ? .max : Int64(bytes) }
        return completed.bytesPerSecond > 0 ? completed.bytesPerSecond : nil
    }
    if let displayed {
        let own = progress?.taskID == displayed.id ? progress : nil
        if let own, own.bytesPerSecond > 0 { return own.bytesPerSecond }
        if let own, own.retainedBytesPerSecond > 0 { return own.retainedBytesPerSecond }
        return displayed.bytesPerSecond > 0 ? displayed.bytesPerSecond : nil
    }
    return state == .waiting && (progress?.retainedBytesPerSecond ?? 0) > 0 ? progress?.retainedBytesPerSecond : nil
}

/// QueueDownloadDisplay.kt. Only the previously visible successful owner gets
/// 120ms fill + 40ms hold. Inputs are conflated; no intermediate task backlog.
struct QueueDownloadMotion {
    private(set) var task: TransferQueueItem?
    private(set) var completing = false
    private(set) var progress = ZTransferScalarAnimation(value: 0)
    private var completion = ZTransferScalarAnimation(value: 0)
    private var accepted: Float = 0
    private var latest: TransferQueueItem?
    private var latestProgress: TransferActiveProgress?
    var isRunning: Bool { progress.isRunning || completion.isRunning }
    init(initialTask: TransferQueueItem? = nil) { task = queueDownloadActiveTask(initialTask) }

    mutating func update(active: TransferQueueItem?, progress sample: TransferActiveProgress?,
                         tasks: [TransferQueueItem], animate: Bool) {
        latest = queueDownloadActiveTask(active); latestProgress = sample
        if !animate {
            let target = queueDownloadTargetProgress(latest, sample)
            accepted = task?.id == latest?.id ? max(accepted, target) : target
            progress.reset(to: accepted); completion.reset(to: 0)
            task = latest; completing = false
            return
        }
        if completing { return }
        if task?.id != latest?.id {
            if let completed = queueDownloadCompletedTask(task?.id, active: latest, tasks: tasks) {
                task = completed; completing = true
                progress.retarget(1, using: .tween(milliseconds: 120), force: true)
                completion.reset(to: 0)
                completion.retarget(1, using: .tween(milliseconds: 160), force: true)
                return
            }
            adoptLatest()
        } else { task = latest; acceptProgress() }
    }

    mutating func advance(_ nanos: Int64) {
        progress.advance(frameNanos: nanos); completion.advance(frameNanos: nanos)
        if completing && !completion.isRunning { completing = false; adoptLatest() }
    }
    private mutating func adoptLatest() {
        task = latest; accepted = 0; progress.reset(to: 0); acceptProgress()
    }
    private mutating func acceptProgress() {
        let fraction = queueDownloadTargetProgress(latest, latestProgress)
        guard fraction > accepted else { return }
        accepted = fraction
        progress.retarget(fraction, using: .criticallyDampedSpring(stiffness: 180, threshold: 0.0005))
    }
}

@MainActor
final class QueueDownloadDisplayModel: ObservableObject {
    @Published private(set) var task: TransferQueueItem?
    @Published private(set) var completing = false
    let progress = AndroidAnimatedOpacity()
    private var motion = QueueDownloadMotion()
    private var link: CADisplayLink?
    init(initialTask: TransferQueueItem? = nil) {
        task = queueDownloadActiveTask(initialTask)
        motion = .init(initialTask: initialTask)
    }
    func update(active: TransferQueueItem?, progress sample: TransferActiveProgress?, tasks: [TransferQueueItem], animate: Bool) {
        motion.update(active: active, progress: sample, tasks: tasks, animate: animate)
        publish()
        if motion.isRunning, link == nil {
            link = ZTransferDisplayLink.make(owner: self) { $0.advance(Int64($1.timestamp * 1_000_000_000)) }
            link?.add(to: .main, forMode: .common)
        } else if !motion.isRunning { stop() }
    }
    func advance(_ nanos: Int64) { motion.advance(nanos); publish(); if !motion.isRunning { stop() } }
    private func publish() {
        if task != motion.task { task = motion.task }
        if completing != motion.completing { completing = motion.completing }
        progress.update(motion.progress.value)
    }
    func stop() { link?.invalidate(); link = nil }
}

struct GenerationRowMotion {
    private(set) var top: ZTransferScalarAnimation
    private(set) var alpha = ZTransferScalarAnimation(value: 0)
    private(set) var success = ZTransferScalarAnimation(value: 0)
    private var hold = ZTransferScalarAnimation(value: 0)
    private(set) var phase: GenerationRowPhase?
    private var notified = false
    var isRunning: Bool { top.isRunning || alpha.isRunning || success.isRunning || hold.isRunning }
    init(position: Int, height: CGFloat) { top = .init(value: Float(CGFloat(position + 1) * (height + 6))) }
    mutating func update(position: Int, height: CGFloat, phase: GenerationRowPhase) {
        let stride = Float(height + 6), base = Float(position) * stride
        top.retarget(phase.retiring ? base - (position == 0 ? stride : 6) : base, using: .tween(milliseconds: 180))
        guard self.phase != phase else { return }
        self.phase = phase; notified = false; hold.reset(to: 0)
        alpha.retarget(phase.retiring ? 0 : 1, using: .tween(milliseconds: phase == .succeeded ? 60 : (phase.retiring ? 140 : 180)), force: true)
        success.retarget(phase.completed ? 1 : 0, using: .tween(milliseconds: 110))
        if phase == .succeeded { hold.retarget(1, using: .tween(milliseconds: 220)) }
    }
    mutating func advance(_ nanos: Int64) -> GenerationRowPhase? {
        top.advance(frameNanos: nanos); alpha.advance(frameNanos: nanos)
        success.advance(frameNanos: nanos); hold.advance(frameNanos: nanos)
        guard let phase, !notified,
              (phase == .succeeded && !hold.isRunning) || (phase.retiring && !alpha.isRunning) else { return nil }
        notified = true; return phase
    }
}

@MainActor
final class GenerationRowsModel: ObservableObject {
    @Published private(set) var rows: [GenerationRowSnapshot] = []
    private var tasks: [TransferQueueItem] = [], history: [TransferQueueItem] = []
    func update(tasks: [TransferQueueItem], history: [TransferQueueItem]) {
        self.tasks = tasks; self.history = history; reconcile()
    }
    func finish(id: UUID, phase: GenerationRowPhase) {
        let finished = finishGenerationRowPhase(rows, id: id, expected: phase)
        let next = generationRowSnapshots(previous: finished, tasks: tasks, allTasks: history)
        if next != rows { rows = next }
    }
    private func reconcile() {
        let next = generationRowSnapshots(previous: rows, tasks: tasks, allTasks: history)
        if next != rows { rows = next }
    }
    func reset() { rows = []; tasks = []; history = [] }
}

@MainActor
final class GenerationRowAnimator: ObservableObject {
    @Published private(set) var motion: GenerationRowMotion
    var onFinish: ((GenerationRowPhase) -> Void)?
    private var link: CADisplayLink?
    init(position: Int, height: CGFloat) { motion = .init(position: position, height: height) }
    func update(position: Int, height: CGFloat, phase: GenerationRowPhase) {
        motion.update(position: position, height: height, phase: phase)
        guard motion.isRunning, link == nil else { return }
        link = ZTransferDisplayLink.make(owner: self) { owner, link in
            let finished = owner.motion.advance(Int64(link.timestamp * 1_000_000_000))
            if !owner.motion.isRunning { owner.stop() }
            if let finished { owner.onFinish?(finished) }
        }
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
}
