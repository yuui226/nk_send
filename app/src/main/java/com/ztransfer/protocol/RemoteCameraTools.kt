package com.ztransfer.protocol

/** Property identities from libgphoto2 camlibs/ptp2/ptp.h. No mode-changing commands here. */
internal enum class RemoteCameraTool { WHITE_BALANCE, FOCUS_AREA, FOCUS_MODE }
internal fun remoteToolPropertyCandidates(tool: RemoteCameraTool, movie: Boolean): List<Int> = when (tool) {
    RemoteCameraTool.FOCUS_MODE -> focusModeProperties
    RemoteCameraTool.WHITE_BALANCE -> if (movie) listOf(0xD23A, 0xD1A7) else listOf(0x5005)
    RemoteCameraTool.FOCUS_AREA -> if (movie) listOf(0xD1F8) else listOf(0x501C, 0xD05D)
}

internal suspend fun NikonCamera.rcGetCameraTool(
    tool: RemoteCameraTool,
    movie: Boolean,
    log: (String) -> Unit = {},
): RcParam? {
    if (tool == RemoteCameraTool.FOCUS_MODE) {
        return readFocusModeCapability { rcGetParam(it, log) }
    }
    var readable: RcParam? = null
    for (prop in remoteToolPropertyCandidates(tool, movie)) {
        val param = rcGetParam(prop, log) ?: continue
        if (readable == null) readable = param
        if (param.writable && param.values.isNotEmpty()) return param
    }
    return readable
}

// Standard active-mode property first; legacy live-view and still fallbacks are separate encodings.
internal val focusModeProperties = listOf(Lab.PROP_FOCUS_MODE, Lab.PROP_NK_STILL_FOCUS_MODE, Lab.PROP_NK_AF_MODE)
internal fun validFocusModeParam(param: RcParam): Boolean = when (param.prop) {
    Lab.PROP_FOCUS_MODE -> param.dataType == 0x0004
    Lab.PROP_NK_STILL_FOCUS_MODE, Lab.PROP_NK_AF_MODE -> param.dataType == 0x0002
    else -> false
}

internal fun rcFocusModeLabel(prop: Int, value: Long): String? = when (prop) {
    Lab.PROP_FOCUS_MODE -> when (value) {
        1L -> "MF"
        2L -> "AF"
        3L -> "AF Macro"
        0x8010L -> "AF-S"
        0x8011L -> "AF-C"
        0x8012L -> "AF-A"
        0x8013L -> "AF-F"
        else -> null
    }
    Lab.PROP_NK_STILL_FOCUS_MODE -> when (value) {
        0L -> "AF-S"
        1L -> "AF-C"
        2L -> "AF-F"
        3L -> "MF (fixed)"
        4L -> "MF"
        5L -> "AF-A" // Live-view AF-A extension; other focus properties use different encodings.
        else -> null
    }
    Lab.PROP_NK_AF_MODE -> when (value) {
        0L -> "AF-S"
        1L -> "AF-C"
        2L -> "AF-A"
        // Keep the project's observed ambiguous 3/4 values unknown.
        else -> null
    }
    else -> null
}
internal fun rcFocusModeManual(prop: Int, value: Long): Boolean =
    (prop == Lab.PROP_FOCUS_MODE && value == 1L) ||
        (prop == Lab.PROP_NK_STILL_FOCUS_MODE && value in 3L..4L)

/** Prefer an explicitly writable capability; retain read-only data if none can be set. */
internal suspend fun readFocusModeCapability(read: suspend (Int) -> RcParam?): RcParam? {
    var readable: RcParam? = null
    for (prop in focusModeProperties) {
        val param = read(prop) ?: continue
        if (param.prop != prop || !validFocusModeParam(param)) continue
        if (readable == null) readable = param
        if (param.writable && param.values.isNotEmpty()) return param
    }
    return readable
}
