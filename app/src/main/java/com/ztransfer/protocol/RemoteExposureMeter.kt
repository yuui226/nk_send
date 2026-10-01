package com.ztransfer.protocol

/** Nikon LightMeter: libgphoto2 config.c _get_Nikon_LightMeter uses signed INT8 / 12 EV.
 * D1B1: one raw unit is one minor tick (one third of the displayed major unit),
 * confirmed by the user’s Z30 camera-meter comparison.
 * Keep the existing D10A conversion independent from that fallback.
 */
internal const val NIKON_LIGHT_METER = 0xD10A
internal const val NIKON_EXPOSURE_INDICATE = 0xD1B1

internal fun rcExposureMeterEv(param: RcParam?): Float? {
    if (param == null || param.dataType != 0x0001 || param.writable) return null
    return when (param.prop) {
        NIKON_LIGHT_METER -> param.current.takeIf { it in -60L..60L }?.let { it / 12f }
        NIKON_EXPOSURE_INDICATE -> param.current.takeIf { it in -128L..127L }?.let { it / 3f }
        else -> null
    }
}

/** Require an exact scalar payload; a truncated/unknown response must never become zero EV. */
internal suspend fun NikonCamera.rcReadExposureMeter(param: RcParam): RcParam? {
    if (param.prop !in listOf(NIKON_LIGHT_METER, NIKON_EXPOSURE_INDICATE) ||
        param.dataType != 0x0001 || param.writable) return null
    val (response, data) = labCommand(Lab.GET_DEVICE_PROP_VALUE, param.prop)
    return rcDecodeExposureMeterValue(param, response, data)
}

internal fun rcDecodeExposureMeterValue(param: RcParam, response: Int, data: ByteArray?): RcParam? {
    if (param.prop !in listOf(NIKON_LIGHT_METER, NIKON_EXPOSURE_INDICATE) ||
        param.dataType != 0x0001 || param.writable || response != Lab.OK || data?.size != 1) return null
    return param.copy(current = data[0].toLong())
}

internal fun rcExposureMeterFresh(startedAt: Long, now: Long): Boolean =
    now >= startedAt && now - startedAt < 1_500L
