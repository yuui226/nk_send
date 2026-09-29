package com.ztransfer.filter

internal enum class PhotoLutExecution(val batchPixels: Int, val label: String) {
    KOTLIN(0, "Kotlin"),
    NATIVE_16K(16 * 1024, "Native16K"),
}
