import Foundation

/// Android TransferSpeedDisplaySampler.kt: one sampler per actual download.
/// Byte counts and progress keep their original cadence. No timer or averaging.
struct TransferSpeedDisplaySampler {
    private var publishedAtMs: Int64?
    private var displayedBytesPerSecond: Int64 = 0

    mutating func sample(_ bytesPerSecond: Int64, nowMs: Int64) -> Int64 {
        if bytesPerSecond > 0,
           publishedAtMs.map({ nowMs - $0 >= 600 }) ?? true {
            displayedBytesPerSecond = bytesPerSecond
            publishedAtMs = nowMs
        }
        return displayedBytesPerSecond
    }
}
