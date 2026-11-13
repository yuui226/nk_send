package com.ztransfer.filter

/**
 * Classic NP3 color controls for developed sRGB photos, independent of camera write datasets.
 * Quarter-step units and monochrome enums follow Nikon Z 30 MTP §9.8; container mappings are
 * verified by the bundled source files and six paired camera exports. Basic style IDs are also
 * independently documented by ExifTool Nikon.pm and Pinksert/Nikon-Picture-Control-NCP-Analysis.
 * The file names a Nikon base style; it does not contain Nikon's proprietary rendering algorithm.
 */
internal object ClassicPhotoNp3Parser {
    fun parse(fields: Map<Int, ByteArray>, version: String): ClassicNp3PhotoFilterParameters {
        supported(version == "0300" || version == "0310", "Unsupported classic NP3 version")
        val lastTag = if (version == "0300") 0x1600 else 0x2000
        val known = (0x0100..lastTag step 0x100).toSet() + setOf(0x02, 0x10100)
        supported(fields.keys.all { it in known }, "Unsupported classic NP3 field")
        fun field(tag: Int, size: Int = 2): ByteArray =
            (fields[tag] ?: invalid("Missing classic NP3 field ${tag.hex()}"))
                .also { valid(it.size == size, "Invalid classic NP3 field length ${tag.hex()}") }
        fun raw(tag: Int, encoding: Int): Int = field(tag).let {
            supported(it[1].unsigned() == encoding, "Unsupported classic NP3 encoding ${tag.hex()}")
            it[0].unsigned()
        }
        fun inactive(tag: Int, encoding: Int, neutral: Int = 128) {
            supported(raw(tag, encoding) in setOf(255, neutral), "Unsupported classic NP3 adjustment ${tag.hex()}")
        }
        val baseBytes = field(0x0300)
        val baseId = (baseBytes[0].unsigned() shl 8) or baseBytes[1].unsigned()
        val base = ClassicNp3Style.fromNp3Id(baseId) ?: unsupported("Unsupported classic NP3 base")
        val creative = base.creative
        val monochrome = base.monochrome
        val fixedToning = baseId in 0x080D..0x0810
        supported(field(0x0400).contentEquals(byteArrayOf(0, 0)), "Unsupported classic NP3 adjustment mode")
        // Obsolete quick adjustments and Auto-mode relative adjustments cannot be guessed.
        inactive(0x0500, 1)
        for (tag in 0x0F00..0x1300 step 0x100) inactive(tag, 1)

        val curve = fields[0x02]?.let(::curve)
        fun scalar(tag: Int, range: IntRange, auto: Boolean = false, curveOwned: Boolean = false): Int {
            val value = raw(tag, 4)
            if (value == 255) return 0 // Not applicable for this base, never a maximum adjustment.
            if (value == 0 && auto) return CLASSIC_PHOTO_FILTER_AUTO
            if (value == 1 && curveOwned) {
                valid(curve != null, "Classic NP3 curve-owned adjustment has no curve")
                return 0
            }
            val decoded = value - 128
            valid(decoded in range, "Classic NP3 adjustment is out of range ${tag.hex()}")
            // The recorded curve already owns contrast and brightness, including its black/white
            // points and gamma. Do not apply either the slider or the editing metadata again.
            return if (curveOwned && curve != null) 0 else decoded
        }
        // These detail controls are validated but not reapplied to an already developed photo.
        scalar(0x0600, -12..36, auto = true)
        scalar(0x0700, -20..20, auto = true)
        scalar(0x1600, -20..20, auto = true)
        val quickSharp = raw(0x1400, 1)
        valid(quickSharp in setOf(0, 255) || quickSharp - 128 in -2..2, "Invalid classic NP3 quick sharpening")

        val contrast = scalar(0x0800, -12..12, auto = true, curveOwned = true)
        val brightness = scalar(0x0900, -6..6, curveOwned = true)
        val saturation = scalar(0x0A00, -12..12, auto = true)
        val hue = scalar(0x0B00, -12..12)
        if (monochrome) supported(saturation == 0 && hue == 0, "Unsupported classic monochrome color adjustment")
        fun enumeration(tag: Int, range: IntRange): Int {
            val value = raw(tag, 0)
            if (value == 255) return 0
            return (value - 128).also { valid(it in range, "Invalid classic NP3 monochrome adjustment") }
        }
        val filter = enumeration(0x0C00, 0..4)
        val toning = enumeration(0x0D00, 0..9)
        val density = scalar(0x0E00, 0..28)
        if (!monochrome) supported(filter == 0 && toning == 0 && density == 0,
            "Unsupported classic color preset monochrome adjustment")
        if (fixedToning) supported(toning == 0, "Unsupported classic fixed-tone override")
        val effect = raw(0x1500, 10)
        val effectLevel = if (creative) {
            valid(effect in 128..138, "Invalid classic NP3 creative effect level")
            (effect - 128) * 10
        } else {
            supported(effect == 255 || effect == 128, "Unexpected classic NP3 creative effect level")
            100
        }
        if (version == "0310") {
            inactive(0x1700, 4)
            inactive(0x1800, 4)
            for (tag in 0x1900..0x1D00 step 0x100) {
                val value = raw(tag, 1)
                supported(value == 128 || value == 1 && curve != null,
                    "Unsupported additional classic NP3 tonal adjustment")
            }
            supported(raw(0x1E00, 1) == 128, "Unsupported additional classic NP3 saturation")
            val mixer = field(0x1F00, 28)
            supported(mixer.take(24).all { it.unsigned() == 128 } &&
                mixer.copyOfRange(24, 28).contentEquals(byteArrayOf(1, 1, 1, 0)),
                "Unsupported additional classic NP3 mixer")
            neutralGrading(field(0x2000, 20))
        }
        fields[0x10100]?.let {
            valid(it.isNotEmpty() && it.size % 2 == 0, "Invalid classic NP3 comment length")
            val end = it.indexOf(0)
            valid(end >= 0 && it.drop(end).all { byte -> byte == 0.toByte() }, "Invalid classic NP3 comment terminator")
        }
        return ClassicNp3PhotoFilterParameters(
            base = base, contrastQuarter = contrast, brightnessQuarter = brightness,
            saturationQuarter = saturation, hueQuarter = hue,
            filterEffect = filter, toningEffect = toning, toningDensityQuarter = density,
            effectLevel = effectLevel, toneCurve = curve,
        )
    }

    private fun curve(bytes: ByteArray): IntArray {
        valid(bytes.size == 578, "Invalid classic NP3 tone curve length")
        supported(bytes[0] == 0x49.toByte() && bytes[1] == 0x30.toByte(), "Unsupported classic NP3 tone curve layout")
        valid(bytes[8].unsigned() <= 20, "Invalid classic NP3 tone curve point count")
        // The rest of the 64-byte header belongs to the curve editor. Non-default levels/gamma
        // occur in the bundled presets; the 257 samples already incorporate those settings.
        return IntArray(PHOTO_FILTER_TONE_CURVE_POINT_COUNT) { index ->
            val offset = 64 + index * 2
            ((bytes[offset].unsigned() shl 8) or bytes[offset + 1].unsigned()).also {
                valid(it in 0..PHOTO_FILTER_TONE_CURVE_MAX_VALUE, "Invalid classic NP3 tone curve sample")
            }
        }
    }

    private fun neutralGrading(bytes: ByteArray) {
        supported(bytes.copyOfRange(12, 16).contentEquals(byteArrayOf(1, 1, 1, 0)) &&
            bytes[17].unsigned() == 1 && bytes[19].unsigned() == 1, "Unsupported classic NP3 grading encoding")
        for (offset in listOf(0, 4, 8)) {
            val hue = ((bytes[offset].unsigned() - 128) shl 8) or bytes[offset + 1].unsigned()
            valid(hue in 0..360, "Invalid classic NP3 grading hue")
            supported(bytes[offset + 2].unsigned() == 128 && bytes[offset + 3].unsigned() == 128,
                "Unsupported additional classic NP3 grading")
        }
        valid(bytes[16].unsigned() - 128 in 0..100 && bytes[18].unsigned() - 128 in -100..100,
            "Invalid classic NP3 grading blend")
    }

    private fun Byte.unsigned() = toInt() and 255
    private fun Int.hex() = "0x" + toString(16)
    private fun valid(condition: Boolean, message: String) { if (!condition) invalid(message) }
    private fun supported(condition: Boolean, message: String) { if (!condition) unsupported(message) }
    private fun invalid(message: String): Nothing = throw PhotoNp3Exception(PhotoNp3Failure.INVALID, message)
    private fun unsupported(message: String): Nothing = throw PhotoNp3Exception(PhotoNp3Failure.UNSUPPORTED, message)
}
