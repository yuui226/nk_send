import Foundation

/// ContinuousClock includes system sleep and is unaffected by wall-clock edits.
/// A process-local origin keeps the same monotonic millisecond domain in the
/// queue and the 200 ms UI refresh, without retaining calendar dates in recipes.
enum PhotoGenerationClock {
    private static let origin = ContinuousClock.now
    static func now() -> Int64 {
        let duration = origin.duration(to: .now).components
        return max(0, duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }
}

extension TransferQueueItem {
    /// Android TransferTask.queue/start/pause/finishFrameGeneration.
    mutating func queueFrameGeneration() {
        isGeneratingFrame = true
        frameGenerationSkipped = false
        frameError = nil
        frameGenerationStartedAtElapsedMs = nil
        frameGenerationElapsedMs = nil
        frameGenerationAccumulatedMs = 0
    }
    mutating func startFrameGeneration(now: Int64) {
        isGeneratingFrame = true
        frameGenerationSkipped = false
        frameError = nil
        frameGenerationStartedAtElapsedMs = now
        frameGenerationElapsedMs = nil
    }
    mutating func skipFrameGeneration() {
        frameError = nil
        frameGenerationSkipped = effects?.hasEffect == true
        isGeneratingFrame = false
        frameGenerationStartedAtElapsedMs = nil
        frameGenerationElapsedMs = nil
    }
    mutating func pauseFrameGeneration(now: Int64) {
        if let start = frameGenerationStartedAtElapsedMs {
            frameGenerationAccumulatedMs += max(0, now - start)
        }
        frameGenerationStartedAtElapsedMs = nil
    }
    mutating func finishFrameGeneration(now: Int64, savedOutput: Bool) {
        guard isGeneratingFrame else { return }
        let elapsed = frameGenerationStartedAtElapsedMs.map {
            frameGenerationAccumulatedMs + max(0, now - $0)
        } ?? (frameGenerationAccumulatedMs > 0 ? frameGenerationAccumulatedMs : nil)
        isGeneratingFrame = false
        frameGenerationStartedAtElapsedMs = nil
        frameGenerationElapsedMs = savedOutput ? elapsed : nil
    }
    func displayedFrameGenerationElapsedMs(now: Int64) -> Int64? {
        guard isGeneratingFrame else { return frameGenerationElapsedMs }
        // A paused crop waiting for metadata hides the stopwatch, just as on Android.
        return frameGenerationStartedAtElapsedMs.map { frameGenerationAccumulatedMs + max(0, now - $0) }
    }
}
