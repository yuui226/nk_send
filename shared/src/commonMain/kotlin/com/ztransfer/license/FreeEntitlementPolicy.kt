package com.ztransfer.license

/** Free-edition limits shared by every platform. Platform stores own the daily counters. */
const val FREE_DAILY_TRANSFER_LIMIT = 25
const val FREE_MAX_FILE_BYTES = 400L * 1024L * 1024L
const val FREE_REMOTE_DAILY_MS = 3L * 60_000L

/** Pro has no transfer-count limit; free usage is clamped only after subtracting the daily count. */
fun dailyTransferQuotaRemaining(isPro: Boolean, transfersDoneToday: Int): Int =
    if (isPro) Int.MAX_VALUE
    else (FREE_DAILY_TRANSFER_LIMIT - transfersDoneToday).coerceAtLeast(0)

fun hasReachedDailyTransferLimit(isPro: Boolean, transfersDoneToday: Int): Boolean =
    !isPro && transfersDoneToday >= FREE_DAILY_TRANSFER_LIMIT

/** A file exactly at the free limit remains allowed. */
fun exceedsFreeFileSizeLimit(isPro: Boolean, sizeBytes: Long): Boolean =
    !isPro && sizeBytes > FREE_MAX_FILE_BYTES

/** Pro has no remote-viewing time limit; exhausted free time remains at zero. */
fun dailyRemoteTimeRemainingMs(isPro: Boolean, usedTodayMs: Long): Long =
    if (isPro) Long.MAX_VALUE
    else (FREE_REMOTE_DAILY_MS - usedTodayMs).coerceAtLeast(0L)
