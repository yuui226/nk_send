package com.ztransfer.protocol

/** Custom slots are explicit protocol IDs, never positions in an occupied-slot list. */
internal const val NIKON_PICTURE_CONTROL_C9 = 209
internal val NIKON_PICTURE_CONTROL_SLOTS = 201..209
internal const val NIKON_PICTURE_CONTROL_STANDARD = 1

/**
 * Classic dataset documented in Nikon Z 30 MTP section 9.8 and observed in its USB
 * v3 / Wi-Fi v2 captures. GetPicCtrlData and SetPicCtrlData use this same dataset.
 * This is not an NP3 container. Different layouts are rejected.
 * The slot comes from the request. The first two response bytes identify the BASE
 * Picture Control (e.g. C1=201 returns base 111), and must never be replaced by 209.
 */
internal class NikonPictureControlData private constructor(
    val requestedItem: Int,
    val baseItem: Int,
    val name: String,
    val isEmpty: Boolean,
    val curve: NikonPictureControlToneCurve?,
    private val source: ByteArray,
) {
    fun bytes(): ByteArray = source.copyOf()
    // Includes QuickSharpFlag at offset 23; preserve it in backups.
    fun parameterBytes(): ByteArray = source.copyOfRange(22, 35)

    companion object {
        fun parseResponse(item: Int, responseCode: Int, bytes: ByteArray?): NikonPictureControlData {
            require(item in 1..65535) { "Invalid Picture Control item" }
            check(responseCode == 0x2001) { "Picture Control read failed: 0x%04X".format(responseCode) }
            requireNotNull(bytes) { "Missing Picture Control data" }
            require(bytes.size == 36 || bytes.size == 614) { "Unrecognized Picture Control dataset size" }
            val source = bytes.copyOf()
            val empty = source.all { it == 0.toByte() }
            if (empty) {
                require(item in 201..209 && source.size == 36) { "Invalid empty Picture Control data" }
                return NikonPictureControlData(item, 0, "", true, null, source)
            }
            val base = (source[0].toInt() and 255) or ((source[1].toInt() and 255) shl 8)
            require(base != 0) { "Missing Picture Control base" }
            val nameBytes = source.copyOfRange(2, 22)
            val nameLength = nameBytes.indexOf(0).let { if (it < 0) nameBytes.size else it }
            require(nameLength in 1..19 && nameBytes.take(nameLength).all { it in 32..126 }) {
                "Unrecognized Picture Control name encoding"
            }
            require(nameBytes.drop(nameLength).all { it == 0.toByte() }) { "Invalid Picture Control name padding" }
            val curve = when (source[35].toInt() and 255) {
                0 -> { require(source.size == 36) { "Unexpected data after Picture Control header" }; null }
                1 -> {
                    require(source.size == 614) { "Truncated Picture Control curve" }
                    NikonPictureControlToneCurve.parse(source.copyOfRange(36, source.size))
                }
                else -> error("Unrecognized Picture Control curve flag")
            }
            return NikonPictureControlData(item, base,
                nameBytes.copyOfRange(0, nameLength).toString(Charsets.US_ASCII), false, curve, source)
        }
    }
}

/**
 * The observed 578-byte I0 curve block is also present in NP3 tag 0x02.
 * Keep all bytes, including its header and control points; a lookup-only backup loses data.
 * 257 big-endian samples at offset 64 are consistent with the independent NP3 reader:
 * https://github.com/ssssota/nikon-flexible-color-picture-control/blob/main/src/deserialize.ts
 */
internal class NikonPictureControlToneCurve private constructor(private val source: ByteArray) {
    data class Point(val x: Int, val y: Int)

    fun bytes(): ByteArray = source.copyOf()
    val points: List<Point>
        get() = List(source[8].toInt() and 255) { index ->
            Point(source[9 + index * 2].toInt() and 255, source[10 + index * 2].toInt() and 255)
        }
    fun samples(): IntArray = IntArray(257) { index ->
        ((source[64 + index * 2].toInt() and 255) shl 8) or (source[65 + index * 2].toInt() and 255)
    }

    companion object {
        fun parse(bytes: ByteArray): NikonPictureControlToneCurve {
            require(bytes.size == 578 && bytes[0] == 0x49.toByte() && bytes[1] == 0x30.toByte()) {
                "Unrecognized Picture Control tone curve"
            }
            require((bytes[8].toInt() and 255) <= 20) { "Invalid Picture Control curve point count" }
            return NikonPictureControlToneCurve(bytes.copyOf()).also { curve ->
                require(curve.samples().all { it in 0..32767 }) { "Invalid Picture Control curve sample" }
            }
        }
    }
}
