package com.ztransfer.protocol

/** Read current and legacy headers together; never switch camera/control modes. */
internal suspend fun NikonCamera.probeLegacyVideoTime(): String {
    val currentOperation = liveViewImageOperation ?: Lab.NK_GET_LIVE_VIEW_IMG
    val reports = mutableListOf(
        "camera=$deviceModel transport=$connectionType pc=$remoteControlModeSet currentOp=${currentOperation.toString(16)}"
    )
    for (operation in listOf(currentOperation, Lab.NK_GET_LIVE_VIEW_IMG).distinct()) {
        val (response, data) = labCommand(operation)
        val payload = data ?: byteArrayOf()
        val jpeg = (0 until minOf(payload.size - 2, 2048).coerceAtLeast(0)).firstOrNull {
            payload[it] == 0xff.toByte() && payload[it + 1] == 0xd8.toByte() &&
                payload[it + 2] == 0xff.toByte()
        }
        val time = if (response == Lab.OK && jpeg != null)
            parseLiveViewPacketVideoTime(payload, jpeg, operation, deviceModel) else null
        val summary = "op=${operation.toString(16)} resp=${response.toString(16)} bytes=${payload.size} header=$jpeg remainingMs=$time"
        // Raw bytes distinguish an unknown layout from a valid but empty video block.
        // Never include JPEG content or interpret offsets from an unknown operation/layout.
        fun hex(start: Int, end: Int): String =
            if (jpeg == null || end > jpeg || end > payload.size) "unavailable"
            else (start until end).joinToString("") { "%02X".format(payload[it].toInt() and 255) }
        val block = when {
            operation == Lab.NK_GET_LIVE_VIEW_IMG && jpeg == 384 -> "video[64..68]=${hex(64, 69)}"
            operation == Lab.NK_GET_LIVE_VIEW_IMG_EX && jpeg == 512 -> "video[380..392]=${hex(380, 393)}"
            operation == Lab.NK_GET_LIVE_VIEW_IMG_EX && jpeg == 1024 -> "video[816..828]=${hex(816, 829)}"
            else -> "unknown video layout"
        }
        reports += "$summary\nheader[0..31]=${hex(0, 32)} $block"
    }
    return reports.joinToString("\n")
}
