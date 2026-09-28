package com.ztransfer.protocol

/** Nikon LightMeter: libgphoto2 config.c _get_Nikon_LightMeter uses signed INT8 / 12 EV.
 * D1B1 scale is marked FIXME in upstream; collect it for diagnostics only.
 * Only the conservative -5..+5 EV interval is currently displayed.
 */
internal const val NIKON_LIGHT_METER = 0xD10A
internal const val NIKON_EXPOSURE_INDICATE = 0xD1B1

internal fun rcExposureMeterEv(param: RcParam?): Float? {
    if (param == null || param.prop != NIKON_LIGHT_METER || param.dataType != 0x0001 ||
        param.writable || param.current !in -60L..60L) return null
    return param.current / 12f
}

/** Require an exact scalar payload; a truncated/unknown response must never become zero EV. */
internal suspend fun NikonCamera.rcReadExposureMeter(param: RcParam, diagnosticLog: ((String) -> Unit)? = null): RcParam? {
    if (param.prop !in listOf(NIKON_LIGHT_METER, NIKON_EXPOSURE_INDICATE) ||
        param.dataType != 0x0001 || param.writable) return null
    val (response, data) = labCommand(Lab.GET_DEVICE_PROP_VALUE, param.prop)
    if (response != Lab.OK || data?.size != 1) {
        diagnosticLog?.invoke("read prop=0x${param.prop.toString(16)} response=0x${response.toString(16)} bytes=${data?.size ?: 0}")
    }
    return rcDecodeExposureMeterValue(param, response, data)
}

internal fun rcDecodeExposureMeterValue(param: RcParam, response: Int, data: ByteArray?): RcParam? {
    if (param.prop !in listOf(NIKON_LIGHT_METER, NIKON_EXPOSURE_INDICATE) ||
        param.dataType != 0x0001 || param.writable || response != Lab.OK || data?.size != 1) return null
    return param.copy(current = data[0].toLong())
}

internal fun rcExposureMeterFresh(startedAt: Long, now: Long): Boolean =
    now >= startedAt && now - startedAt < 1_500L
