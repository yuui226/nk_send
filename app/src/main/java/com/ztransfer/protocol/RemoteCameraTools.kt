package com.ztransfer.protocol

import kotlin.math.roundToInt

/** Property identities from libgphoto2 camlibs/ptp2/ptp.h. No mode-changing commands here. */
internal enum class RemoteCameraTool { WHITE_BALANCE, FOCUS_AREA, FOCUS_MODE }

/**
 * 点按对焦的两条机身路径：主体追踪和移动 AF 区域。
 * UNKNOWN 保留旧的能力探测回退，避免未知机型因为标签不完整而失去原有能力。
 */
enum class RcTapFocusPath { TRACKING, MOVE_AREA, UNSUPPORTED, UNKNOWN }

/**
 * Map a viewfinder fraction to a Nikon AF command coordinate.
 *
 * The command domain is the full Live View coordinate domain (the enhanced
 * frame's +16/+18 values), not the smaller AF-frame metadata grid at +28/+30.
 */
internal fun rcNormalizedToFocusCoordinate(normalized: Float, size: Int): Int {
    if (size <= 1) return 0
    return (normalized.coerceIn(0f, 1f) * (size - 1)).roundToInt()
}

internal fun rcTapFocusPath(param: RcParam?, model: String?): RcTapFocusPath {
    if (param == null) return RcTapFocusPath.UNKNOWN
    val body = model.orEmpty().trim().uppercase(java.util.Locale.ROOT).removePrefix("NIKON").trim()
    val zFamily = body.startsWith("Z")
    return when (param.prop) {
        // Z 系照片/录像枚举：自动区域及主体检测走 StartTracking，
        // 单点、精准点、动态区域、宽区域、群组区域走 ChangeAfArea。
        0x501C, 0xD1F8 -> when (param.current) {
            0x8011L, 0x8012L, 0x801AL, 0x801BL,
            0x8020L, 0x8021L -> RcTapFocusPath.TRACKING
            0x8010L, 0x8015L, 0x8017L, 0x8018L, 0x8019L,
            0x801EL, 0x801FL, 2L, 0x8013L, 0x8014L -> RcTapFocusPath.MOVE_AREA
            else -> if (zFamily) RcTapFocusPath.UNSUPPORTED else RcTapFocusPath.UNKNOWN
        }
        // 老属性的值域不是 Z 系扩展值，按 libgphoto2 的 Live View AF 映射处理。
        0xD05D -> when (param.current) {
            // 老机型的基础枚举：人脸优先 / 主体跟踪。
            0L, 3L -> RcTapFocusPath.TRACKING
            1L, 2L, 4L -> RcTapFocusPath.MOVE_AREA
            // Z30 照片模式实际从 D05D 返回扩展枚举，与 501C/D1F8 共用值域。
            0x8011L, 0x8012L, 0x801AL, 0x801BL,
            0x8020L, 0x8021L -> RcTapFocusPath.TRACKING
            0x8010L, 0x8015L, 0x8017L, 0x8018L, 0x8019L,
            0x801EL, 0x801FL, 0x8013L, 0x8014L -> RcTapFocusPath.MOVE_AREA
            else -> RcTapFocusPath.UNKNOWN
        }
        else -> RcTapFocusPath.UNKNOWN
    }
}

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
