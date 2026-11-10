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
    mutating func queueFrameGeneration(pendingCheck: Bool = false) {
        isGeneratingFrame = true
        frameGenerationPendingCheck = pendingCheck
        frameGenerationSkipped = false
        frameError = nil
        frameGenerationStartedAtElapsedMs = nil
        frameGenerationElapsedMs = nil
        frameGenerationAccumulatedMs = 0
    }
    mutating func startFrameGeneration(now: Int64) {
        isGeneratingFrame = true
        frameGenerationPendingCheck = false
        frameGenerationSkipped = false
        frameError = nil
        frameGenerationStartedAtElapsedMs = now
        frameGenerationElapsedMs = nil
    }
    mutating func skipFrameGeneration() {
        frameError = nil
        frameGenerationSkipped = effects?.hasEffect == true
        isGeneratingFrame = false
        frameGenerationPendingCheck = false
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
        frameGenerationPendingCheck = false
        frameGenerationStartedAtElapsedMs = nil
        frameGenerationElapsedMs = savedOutput ? elapsed : nil
    }
    func displayedFrameGenerationElapsedMs(now: Int64) -> Int64? {
        guard isGeneratingFrame else { return frameGenerationElapsedMs }
        // A paused crop waiting for metadata hides the stopwatch, just as on Android.
        return frameGenerationStartedAtElapsedMs.map { frameGenerationAccumulatedMs + max(0, now - $0) }
    }
}

/// Android canConfirmPhotoGeneration: this only proves missing output for
/// display admission. Exact recipe matching remains in the serial worker.
func canConfirmPhotoGeneration(sourceName: String, knownOutputNames: Set<String>?,
                               sameSourceInProgress: Bool, cropRequested: Bool, hasSavedCrop: Bool) -> Bool {
    if cropRequested { return !hasSavedCrop }
    guard !sameSourceInProgress, let knownOutputNames else { return false }
    let prefix = (sourceName as NSString).deletingPathExtension.lowercased() + "_"
    return !knownOutputNames.contains { $0.lowercased().hasPrefix(prefix) }
}

/// Android clearQueueTargetIds. Busy includes preflight, queued and running
/// generation. Download completion during an exit must not enlarge this set.
func clearQueueTargetIDs(_ items: [TransferQueueItem]) -> Set<UUID> {
    Set(items.lazy.filter { $0.status != .transferring && !$0.isGeneratingFrame }.map(\.id))
}
