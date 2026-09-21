package com.ztransfer.protocol

/** Property identities from libgphoto2 camlibs/ptp2/ptp.h. No mode-changing commands here. */
internal enum class RemoteCameraTool { WHITE_BALANCE, FOCUS_AREA }
internal fun remoteToolPropertyCandidates(tool: RemoteCameraTool, movie: Boolean): List<Int> = when (tool) {
    RemoteCameraTool.WHITE_BALANCE -> if (movie) listOf(0xD23A, 0xD1A7) else listOf(0x5005)
    RemoteCameraTool.FOCUS_AREA -> if (movie) listOf(0xD1F8) else listOf(0x501C, 0xD05D)
}

internal suspend fun NikonCamera.rcGetCameraTool(
    tool: RemoteCameraTool,
    movie: Boolean,
    log: (String) -> Unit = {},
): RcParam? {
    var readable: RcParam? = null
    for (prop in remoteToolPropertyCandidates(tool, movie)) {
        val param = rcGetParam(prop, log) ?: continue
        if (readable == null) readable = param
        if (param.writable && param.values.isNotEmpty()) return param
    }
    return readable
}
