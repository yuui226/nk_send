import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Android Motion.overlayExpand/Collapse. Only render modifiers observe frames;
/// the page owns this reference without observing it. Completion is an actual
/// frame event, so the FHD grace period cannot confuse a target with its display.
@MainActor
final class PhotoPreviewPresentationClock: ObservableObject {
    @Published private(set) var progress: CGFloat = 0
    private var motion = ZTransferScalarAnimation(value: 0)
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private let automaticFrames: Bool
    #if canImport(UIKit)
    private var link: CADisplayLink?
    #endif

    init(automaticFrames: Bool = true) { self.automaticFrames = automaticFrames }
    var isRunning: Bool { motion.isRunning }
    var waitingCount: Int { observers.count }
    func animate(to target: Float) {
        motion.retarget(target, using: .tween(milliseconds: target == 1 ? 340 : 260))
        #if canImport(UIKit)
        guard motion.isRunning, automaticFrames, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.advance(Int64(frame.timestamp * 1_000_000_000))
        }
        link = next; next.add(to: .main, forMode: .common)
        #endif
    }
    func advance(_ nanos: Int64) {
        motion.advance(frameNanos: nanos)
        let value = CGFloat(motion.value)
        if progress != value { progress = value }
        if !motion.isRunning {
            stopDriver()
            for observer in observers.values { observer.yield(true) }
        }
    }
    func stop() {
        stopDriver()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }
    private func stopDriver() {
        #if canImport(UIKit)
        link?.invalidate(); link = nil
        #endif
    }
    func waitUntilRest(at target: CGFloat) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !isRunning, progress == target { return true }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        defer { observers[id] = nil; continuation.finish() }
        for await _ in stream {
            if Task.isCancelled { return false }
            if !isRunning, progress == target { return true }
        }
        return false
    }
    /// Called after the 340 ms layout-based delay. A stalled frame clock must
    /// never prevent FHD/EXIF from starting; cancellation still propagates.
    func waitForOpeningGrace(nanoseconds: UInt64 = 120_000_000) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await self.waitUntilRest(at: 1) }
            group.addTask { try? await Task.sleep(nanoseconds: nanoseconds) }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
