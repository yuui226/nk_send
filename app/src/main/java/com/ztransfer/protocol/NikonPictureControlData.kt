package com.ztransfer.protocol

/** Custom slots are explicit protocol IDs, never positions in an occupied-slot list. */
internal const val NIKON_PICTURE_CONTROL_C9 = 209
internal val NIKON_PICTURE_CONTROL_SLOTS = 201..209
internal const val NIKON_PICTURE_CONTROL_STANDARD = 1

/**
 * Camera datasets, not NP3 containers. The default layout is documented in Nikon
 * Z 30 MTP section 9.8 and observed in its USB v3 / Wi-Fi v2 captures. D5600 uses
 * the separate V2 layout in its MTP section 7.4.3/4; callers must select it explicitly.
 * The slot comes from the request. The leading base ID is UINT16 on Z and UINT8
 * on D5600; it identifies the base style and must never be replaced by a slot ID.
 */
internal class NikonPictureControlData private constructor(
    val requestedItem: Int,
    val baseItem: Int,
    val name: String,
    val isEmpty: Boolean,
    val format: NikonPictureControlFormat,
    // Legacy curve bytes remain opaque for lossless snapshots, including unknown headers.
    val curve: NikonPictureControlToneCurve?,
    private val source: ByteArray,
) {
    fun bytes(): ByteArray = source.copyOf()
    fun parameterBytes(): ByteArray = source.copyOfRange(
        if (format == NikonPictureControlFormat.CLASSIC_Z) 22 else 23, format.headerSize - 1)

    companion object {
        fun parseResponse(item: Int, responseCode: Int, bytes: ByteArray?,
                          format: NikonPictureControlFormat = NikonPictureControlFormat.CLASSIC_Z): NikonPictureControlData {
            require(item in 1..65535) { "Invalid Picture Control item" }
            check(responseCode == 0x2001) { "Picture Control read failed: 0x%04X".format(responseCode) }
            requireNotNull(bytes) { "Missing Picture Control data" }
            require(format.supportsSize(bytes.size)) { "Unrecognized $format Picture Control dataset size: ${bytes.size}" }
            val source = bytes.copyOf()
            if (format == NikonPictureControlFormat.LEGACY_V2) return parseV2(item, source)
            val base = (source[0].toInt() and 255) or ((source[1].toInt() and 255) shl 8)
            // Z8 MTP §9.9.1 defines an unused custom slot by BasePictureControl=0.
            // Its unused name/adjustment/curve bytes need not be zero-filled.
            if (base == 0) {
                require(item in NIKON_PICTURE_CONTROL_SLOTS) { "Invalid empty Picture Control data" }
                return NikonPictureControlData(item, 0, "", true, format, null, source)
            }
            val name = parseName(source.copyOfRange(2, 22))
            val curve = when (source[35].toInt() and 255) {
                0 -> { require(source.size == 36) { "Unexpected data after Picture Control header" }; null }
                1 -> {
                    require(source.size == 614) { "Truncated Picture Control curve" }
                    NikonPictureControlToneCurve.parse(source.copyOfRange(36, source.size))
                }
                else -> error("Unrecognized Picture Control curve flag")
            }
            return NikonPictureControlData(item, base, name, false, format, curve, source)
        }

        private fun parseV2(item: Int, source: ByteArray): NikonPictureControlData {
            val format = NikonPictureControlFormat.LEGACY_V2
            val custom = source[2].toInt() and 255
            if (custom == 2) {
                require(item in NIKON_PICTURE_CONTROL_SLOTS) { "Only a custom slot may be unused" }
                return NikonPictureControlData(item, 0, "", true, format, null, source)
            }
            require(custom == if (item in NIKON_PICTURE_CONTROL_SLOTS) 1 else 0) {
                "Unexpected V2 Picture Control registration flag"
            }
            val base = source[0].toInt() and 255
            require(base in 1..199 && source[1].toInt() in 0..1) { "Invalid V2 Picture Control base" }
            // V2 specifies a NUL-terminated 20-byte field, not zero-filled padding.
            val name = parseName(source.copyOfRange(3, 23), zeroPadding = false)
            when (source[31].toInt()) {
                0 -> Unit // Preserve an unused trailing curve area without interpreting it.
                1 -> require(source.size == 610) { "Truncated V2 Picture Control curve" }
                else -> error("Unrecognized V2 Picture Control curve flag")
            }
            return NikonPictureControlData(item, base, name, false, format, null, source)
        }

        private fun parseName(nameBytes: ByteArray, zeroPadding: Boolean = true): String {
            val nameLength = nameBytes.indexOf(0).let { if (it < 0) nameBytes.size else it }
            require(nameLength in 1..19 && nameBytes.take(nameLength).all { it in 32..126 }) {
                "Unrecognized Picture Control name encoding"
            }
            require(!zeroPadding || nameBytes.drop(nameLength).all { it == 0.toByte() }) { "Invalid Picture Control name padding" }
            return nameBytes.copyOfRange(0, nameLength).toString(Charsets.US_ASCII)
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
