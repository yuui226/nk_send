/// Android FileScanBatchSize.kt; failures count as processed handles too.
func fileScanBatchSize(processed: Int, requested: Int, fastFirstBatch: Bool) -> Int {
    let normal = max(requested, 1)
    guard fastFirstBatch else { return normal }
    if processed == 0 { return 1 }
    if processed < 4 { return min(4 - processed, normal) }
    return normal
}
