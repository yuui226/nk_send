package com.ztransfer.frame

import android.app.ActivityManager
import android.content.Context

/** Saturating arithmetic: malformed dimensions must fail before allocating, never wrap small. */
internal fun photoAllocationBytes(width: Int, height: Int, copies: Int = 1, extraBytes: Long = 0): Long {
    if (width <= 0 || height <= 0 || copies <= 0 || extraBytes < 0) return Long.MAX_VALUE
    return try {
        Math.addExact(Math.multiplyExact(Math.multiplyExact(width.toLong(), height.toLong()),
            Math.multiplyExact(4L, copies.toLong())), extraBytes)
    } catch (_: ArithmeticException) { Long.MAX_VALUE }
}

internal fun photoAllocationFits(required: Long, maximumHeap: Long, usedHeap: Long): Boolean {
    if (required < 0 || usedHeap < 0 || maximumHeap <= 0) return false
    // Leave room for transfer buffers, the UI, and codec/provider bookkeeping. This is an
    // early rejection of clearly unsafe requests, not a guarantee about native allocation.
    val reserve = maxOf(16L * 1024 * 1024, maximumHeap / 8)
    return required <= (maximumHeap - usedHeap.coerceAtMost(maximumHeap) - reserve).coerceAtLeast(0)
}

/** System availability already excludes existing allocations; do not subtract Java usage again. */
internal fun photoNativeAllocationFits(required: Long, available: Long, threshold: Long): Boolean {
    if (required < 0 || required == Long.MAX_VALUE || available <= 0 || threshold < 0) return false
    // Respect the system low-memory threshold, without withholding a percentage of
    // otherwise available RAM on large-memory phones.
    val reserve = maxOf(64L * 1024 * 1024, threshold)
    return required <= (available - reserve).coerceAtLeast(0)
}

internal fun ensurePhotoAllocation(
    context: Context,
    width: Int,
    height: Int,
    copies: Int = 1,
    extraBytes: Long = 0,
    javaBytes: Long = 0,
) {
    val runtime = Runtime.getRuntime()
    val required = photoAllocationBytes(width, height, copies, extraBytes)
    val memory = ActivityManager.MemoryInfo()
    context.getSystemService(ActivityManager::class.java).getMemoryInfo(memory)
    val javaUsed = runtime.totalMemory() - runtime.freeMemory()
    // API 26+ stores bitmap pixels in native memory. maxMemory is only the managed heap limit.
    // This snapshot is an early pressure check, not a reservation or an allocation guarantee.
    if (!photoNativeAllocationFits(required, memory.availMem, memory.threshold) ||
        (javaBytes > 0 && !photoAllocationFits(javaBytes, runtime.maxMemory(), javaUsed))) {
        throw OutOfMemoryError(
            "Photo generation memory budget rejected: estimated=$required bytes; " +
                "systemAvailable=${memory.availMem}; systemThreshold=${memory.threshold}; " +
                "javaRequired=$javaBytes; javaUsed=$javaUsed; javaMax=${runtime.maxMemory()}"
        )
    }
}
