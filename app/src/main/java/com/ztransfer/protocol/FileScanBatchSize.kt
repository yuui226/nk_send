package com.ztransfer.protocol

/** First four handles appear in small batches; subsequent batches use the cache policy. */
internal fun fileScanBatchSize(processed: Int, requested: Int, fastFirstBatch: Boolean): Int {
    val normal = requested.coerceAtLeast(1)
    return if (!fastFirstBatch) normal else when {
        processed == 0 -> 1
        processed < 4 -> minOf(4 - processed, normal)
        else -> normal
    }
}
