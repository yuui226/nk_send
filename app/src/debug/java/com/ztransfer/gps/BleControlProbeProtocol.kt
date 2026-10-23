package com.ztransfer.gps

/** Capability evidence from the BLE control service, never evidence of a network connection. */
internal data class ControlProbeResponse(
    val opcode: Int,
    val responseCode: Int,
    val remoteControl: Boolean? = null,
    /** Whether at least one menu-navigation key group is advertised by Configuration. */
    val keyEvents: Boolean? = null,
    val menu: Boolean? = null,
    val selector: Boolean? = null,
    val details: String,
)

/** Independently encoded protocol facts for a debug-only, manually operated BLE probe. */
internal object BleControlProbeProtocol {
    fun featureQuery(): ByteArray = byteArrayOf(4, 0, 0x01, 0)

    fun configurationQuery(): ByteArray = byteArrayOf(4, 0, 0x10, 0)

    fun remoteMode(enabled: Boolean): ByteArray =
        byteArrayOf(5, 0, 0x11, 0, if (enabled) 1 else 0)

    fun key(key: Int, pressed: Boolean): ByteArray {
        require(key == 5 || key in 7..11) { "Only menu-navigation keys are allowed" }
        return byteArrayOf(6, 0, 0x12, 0, key.toByte(), if (pressed) 1 else 0)
    }

    fun parseResponse(bytes: ByteArray): ControlProbeResponse? {
        if (bytes.size !in 4..0xffff || bytes.u16(0) != bytes.size) return null
        val opcode = bytes.u8(2)
        if (opcode != 0x01 && opcode !in 0x10..0x12) return null
        val code = bytes.u8(3)
        val result = when (code) {
            1 -> "SUCCESS"
            2 -> "OP_CODE_NOT_SUPPORTED"
            3 -> "INVALID_PARAMETER"
            4 -> "OPERATION_FAILED"
            5 -> "ALREADY_IN_PROGRESS"
            0x7f -> "SIZE_ERROR"
            else -> return null
        }
        val header = "op=0x${opcode.hex(2)} response=$result"
        if (code != 1) {
            // Error packets may carry a body; it must not be interpreted as capabilities.
            return ControlProbeResponse(
                opcode = opcode,
                responseCode = code,
                details = header + extraBytes(bytes, 4),
            )
        }
        return when (opcode) {
            0x01 -> parseFeature(bytes, header)
            0x10 -> {
                if (bytes.size < 8) return null
                val flags = bytes.u32(4)
                val menu = flags and 0x10L != 0L
                val selector = flags and 0x40L != 0L
                ControlProbeResponse(
                    opcode = opcode,
                    responseCode = code,
                    keyEvents = menu || selector,
                    menu = menu,
                    selector = selector,
                    details = "$header flags=0x${flags.toString(16).padStart(8, '0')}" +
                        " menu=$menu selector=$selector" + extraBytes(bytes, 8),
                )
            }
            else -> ControlProbeResponse(
                opcode = opcode,
                responseCode = code,
                details = header + extraBytes(bytes, 4),
            )
        }
    }

    private fun parseFeature(bytes: ByteArray, header: String): ControlProbeResponse? {
        if (bytes.size < 6) return null
        val characteristics = bytes.u8(4)
        val cameraControl = bytes.u8(5)
        val remote = cameraControl and 1 != 0
        var consumed = 6
        val details = buildString {
            append(header)
            append(" characteristics=0x${characteristics.hex(2)}")
            append(" cameraControl=0x${cameraControl.hex(2)} remoteControl=$remote")
            if (remote) {
                if (bytes.size < 8) return null
                val remoteFlags = bytes.u16(6)
                consumed = 8
                append(" remoteFlags=0x${remoteFlags.hex(4)}")
                // Shooting-operation flags are present only when shooting events are supported.
                if (remoteFlags and 2 != 0) {
                    if (bytes.size < 10) return null
                    consumed = 10
                    append(" shootingFlags=0x${bytes.u16(8).hex(4)}")
                }
            }
            append(extraBytes(bytes, consumed))
        }
        return ControlProbeResponse(
            opcode = 0x01,
            responseCode = 1,
            remoteControl = remote,
            // Feature has no independent key-event flag. Do not confuse shooting events with keys.
            details = details,
        )
    }

    /** 0x2020 has a five-byte status prefix, without the 0x2021 response header. */
    fun describeStatus(bytes: ByteArray): String {
        if (bytes.size < 5) return "invalid status: bytes=${bytes.size}, need>=5"
        val state = when (bytes.u8(0)) {
            0 -> "NOT_CONTROL"
            1 -> "PHOTO"
            2 -> "PLAY"
            3 -> "MENU"
            else -> "UNKNOWN(0x${bytes.u8(0).hex(2)})"
        }
        // A MENU state cannot reveal which menu item is selected, nor prove STA was enabled.
        return "state=$state sub=0x${bytes.u8(1).hex(2)}" +
            " capture=0x${bytes.u8(2).hex(2)} restrictions=0x${bytes.u8(3).hex(2)}" +
            " focus=0x${bytes.u8(4).hex(2)}" + extraBytes(bytes, 5)
    }

    private fun extraBytes(bytes: ByteArray, consumed: Int): String =
        if (bytes.size > consumed) " extraBytes=${bytes.size - consumed}" else ""

    private fun ByteArray.u8(offset: Int): Int = this[offset].toInt() and 0xff

    private fun ByteArray.u16(offset: Int): Int = u8(offset) or (u8(offset + 1) shl 8)

    private fun ByteArray.u32(offset: Int): Long =
        u16(offset).toLong() or (u16(offset + 2).toLong() shl 16)

    private fun Int.hex(width: Int): String = toString(16).padStart(width, '0')
}
