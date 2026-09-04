package com.ztransfer.protocol

data class DownloadProgress(
    val downloaded: Long,
    val total: Long,
    val bytesPerSecond: Long,
)

/** Statistics for one completed camera download attempt. */
data class DownloadStats(
    val bytes: Long,
    /** Bytes actually transferred during this attempt, excluding an existing resume prefix. */
    val transferredBytes: Long,
    /** Monotonic timestamp at which this file entered the protocol download path. */
    val startedAtElapsedMs: Long,
    /** Optional bounded prefix; producers and consumers treat this mutable byte array as read-only. */
    val headerPrefix: ByteArray? = null,
)
