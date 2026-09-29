package com.ztransfer.frame

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

internal fun ensurePhotoAllocation(width: Int, height: Int, copies: Int = 1, extraBytes: Long = 0) {
    val runtime = Runtime.getRuntime()
    val required = photoAllocationBytes(width, height, copies, extraBytes)
    if (!photoAllocationFits(required, runtime.maxMemory(), runtime.totalMemory() - runtime.freeMemory())) {
        throw OutOfMemoryError("Insufficient photo generation memory: estimated $required bytes")
    }
}
