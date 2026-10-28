package com.ztransfer.filter

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

internal enum class PhotoNp3Failure { INVALID, UNSUPPORTED, TOO_LARGE }

internal class PhotoNp3Exception(
    val reason: PhotoNp3Failure,
    message: String,
) : IllegalArgumentException(message)

internal data class ParsedPhotoNp3(
    val sourceSha256: String,
    val preset: PhotoFilterPreset,
    /** Known camera detail controls are validated, but cannot be reapplied to developed pixels. */
    val ignoredDetailControls: Boolean,
)

/**
 * Converts supported Classic and Flexible Color NP3 profiles into sRGB photo recipes.
 * This is independent of the camera's Classic Picture Control writer.
 *
 * Field meanings and units are checked against the MIT-licensed independent implementation:
 * https://github.com/ssssota/nikon-flexible-color-picture-control (src/base.ts, serialize.ts).
 * The three original regression files in test/resources/picture_control/flexible-color are
 * independent fixtures. Parse TLV tags, never the absolute offsets used by that implementation.
 */
internal object PhotoNp3Parser {
    const val MAX_BYTES = 64 * 1024
    const val CONVERTER_VERSION = "np3-srgb-v1"
    const val CLASSIC_CONVERTER_VERSION = "np3-classic-srgb-v1"

    fun read(input: InputStream, checkpoint: () -> Unit = {}): ParsedPhotoNp3 {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            checkpoint()
            val count = input.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - output.size()))
            if (count < 0) break
            invalidUnless(count > 0, "NP3 stream made no progress")
            if (output.size() + count > MAX_BYTES) fail(PhotoNp3Failure.TOO_LARGE, "NP3 exceeds size limit")
            output.write(buffer, 0, count)
        }
        checkpoint()
        return parse(output.toByteArray())
    }

    fun parse(bytes: ByteArray): ParsedPhotoNp3 {
        if (bytes.size > MAX_BYTES) fail(PhotoNp3Failure.TOO_LARGE, "NP3 exceeds size limit")
        // Own every byte used by the parser; neither the source nor a provider buffer is retained.
        val source = bytes.copyOf()
        val fields = readContainer(source)
        fun field(tag: Int, size: Int): ByteArray {
            val value = fields[tag] ?: fail(PhotoNp3Failure.INVALID, "Missing NP3 field ${tag.hex()}")
            invalidUnless(value.size == size, "Invalid NP3 field length ${tag.hex()}")
            return value
        }

        val versionBytes = field(0x0100, 4)
        invalidUnless(versionBytes.all { it in 48..57 }, "Invalid NP3 version")
        val version = versionBytes.toString(Charsets.US_ASCII)
        val name = parseName(field(0x0200, 20))
        val base = field(0x0300, 2)
        val digest = MessageDigest.getInstance("SHA-256").digest(source)
            .joinToString("") { it.unsigned().toString(16).padStart(2, '0') }
        // An exact source match already has a curated conversion. Preserve that conversion and
        // its original ID even when a newer import policy does not support every source control.
        BuiltInPhotoFilters.all.firstOrNull { BuiltInPhotoFilters.catalogKey(it.id) == digest }?.let {
            return ParsedPhotoNp3(digest, it, ignoredDetailControls = true)
        }
        if (!base.contentEquals(byteArrayOf(0, 0x20))) {
            val parameters = ClassicPhotoNp3Parser.parse(fields, version)
            return ParsedPhotoNp3(
                digest,
                PhotoFilterPreset("np3:$digest:$CLASSIC_CONVERTER_VERSION", name, parameters),
                ignoredDetailControls = true,
            )
        }
        supportedUnless(version == "0310" && base.contentEquals(byteArrayOf(0, 0x20)),
            "Unsupported NP3 version or base Picture Control")
        val knownTags = (0x0100..0x2000 step 0x100).toSet() + setOf(0x02, 0x10100)
        supportedUnless(fields.keys.all { it in knownTags }, "Unsupported NP3 field")

        fun scalar(tag: Int, encoding: Int, range: IntRange): Int {
            val value = field(tag, 2)
            supportedUnless(value[1].unsigned() == encoding, "Unsupported NP3 field encoding ${tag.hex()}")
            return (value[0].unsigned() - 128).also {
                invalidUnless(it in range, "NP3 value is out of range ${tag.hex()}")
            }
        }
        fun fixed(tag: Int, value: Int, encoding: Int) {
            supportedUnless(field(tag, 2).contentEquals(byteArrayOf(value.toByte(), encoding.toByte())),
                "Unsupported NP3 adjustment ${tag.hex()}")
        }

        // The remaining Classic controls are explicitly unavailable/off in this profile.
        fixed(0x0400, 0, 0)
        fixed(0x0500, 255, 1)
        for (tag in 0x0800..0x0B00 step 0x100) fixed(tag, 255, 4)
        for (tag in 0x0C00..0x0D00 step 0x100) fixed(tag, 255, 0)
        fixed(0x0E00, 255, 4)
        for (tag in 0x0F00..0x1300 step 0x100) fixed(tag, 255, 1)
        fixed(0x1500, 255, 10)
        fixed(0x1700, 255, 4)
        fixed(0x1800, 255, 4)

        // Quick sharp controls the three detail adjustments below. Like the Classic importer,
        // recognize manual -2..2, automatic (0), and unavailable (255) without applying a second
        // sharpening pass to an already developed photo.
        val quickSharp = field(0x1400, 2).let {
            supportedUnless(it[1].unsigned() == 1, "Unsupported NP3 field encoding 0x1400")
            it[0].unsigned().also { value ->
                invalidUnless(value == 0 || value == 255 || value - 128 in -2..2,
                    "NP3 quick sharpening is out of range")
            }
        }
        // These are quarter-step camera controls, not the photo renderer's global color controls.
        val detailControls = listOf(
            scalar(0x0600, 4, -12..36),
            scalar(0x0700, 4, -20..20),
            scalar(0x1600, 4, -20..20),
        )
        val curve = fields[0x02]?.let(::parseToneCurve)
        val tonal = (0x1900..0x1D00 step 0x100).map { tag ->
            if (curve != null) {
                val value = field(tag, 2)
                supportedUnless(value[1].unsigned() == 1, "Unsupported NP3 field encoding ${tag.hex()}")
                // 1 is the curve-owned sentinel, not -127. Ordinary manual values are inactive
                // when a curve is present, but still validate them rather than dropping garbage.
                invalidUnless(value[0].unsigned() == 1 || value[0].unsigned() - 128 in -100..100,
                    "Invalid curve-controlled NP3 value ${tag.hex()}")
                0
            } else scalar(tag, 1, -100..100)
        }
        val saturation = scalar(0x1E00, 1, -100..100)
        val mixer = field(0x1F00, 28)
        supportedUnless(mixer.copyOfRange(24, 28).contentEquals(byteArrayOf(1, 1, 1, 0)),
            "Unsupported NP3 color mixer encoding")
        val bands = PHOTO_FILTER_COLOR_BAND_CENTERS.mapIndexed { index, center ->
            val offset = index * 3
            val values = (offset until offset + 3).map { mixer[it].unsigned() - 128 }
            invalidUnless(values.all { it in -100..100 }, "NP3 color mixer value is out of range")
            PhotoFilterColorBand(center, values[0], values[1], values[2])
        }
        val grading = parseColorGrading(field(0x2000, 20))
        fields[0x10100]?.let(::validateComment)

        val parameters = Np3PhotoFilterParameters(
            contrast = tonal[0], highlights = tonal[1], shadows = tonal[2],
            whites = tonal[3], blacks = tonal[4], saturation = saturation,
            colorBands = bands, toneCurve = curve, colorGrading = grading,
        )
        return ParsedPhotoNp3(
            sourceSha256 = digest,
            preset = PhotoFilterPreset("np3:$digest:$CONVERTER_VERSION", name, parameters),
            ignoredDetailControls = detailControls.any { it != 0 } ||
                (quickSharp != 128 && quickSharp != 255),
        )
    }

    private fun readContainer(source: ByteArray): Map<Int, ByteArray> {
        invalidUnless(source.size >= 8 && source.copyOfRange(0, 4).contentEquals(byteArrayOf(78, 67, 80, 0)),
            "Invalid NP3 signature")
        val input = ByteBuffer.wrap(source).order(ByteOrder.BIG_ENDIAN).apply { position(4) }
        val fields = linkedMapOf<Int, ByteArray>()
        while (input.remaining() >= 4) {
            val tag = input.int
            if (tag == 0) {
                invalidUnless(!input.hasRemaining(), "Trailing NP3 data")
                return fields
            }
            invalidUnless(input.remaining() >= 4, "Truncated NP3 field header")
            val length = input.int
            invalidUnless(length >= 0 && length <= input.remaining(), "Truncated NP3 field")
            invalidUnless(tag !in fields, "Duplicate NP3 field")
            fields[tag] = ByteArray(length).also(input::get)
        }
        fail(PhotoNp3Failure.INVALID, "Missing NP3 terminator")
    }

    private fun parseName(bytes: ByteArray): String {
        val end = bytes.indexOf(0)
        invalidUnless(end in 1..19 && bytes.drop(end).all { it == 0.toByte() }, "Invalid NP3 name")
        supportedUnless(bytes.take(end).all { it in 32..126 }, "Unsupported NP3 name encoding")
        return bytes.copyOfRange(0, end).toString(Charsets.US_ASCII).also {
            invalidUnless(it.isNotBlank(), "Empty NP3 name")
        }
    }

    private fun parseToneCurve(bytes: ByteArray): IntArray {
        invalidUnless(bytes.size == 578, "Invalid NP3 tone curve length")
        supportedUnless(bytes[0] == 0x49.toByte() && bytes[1] == 0x30.toByte(),
            "Unsupported NP3 tone curve layout")
        val points = bytes[8].unsigned()
        invalidUnless(points <= 20, "Invalid NP3 tone curve point count")
        // Black/white levels, gamma and control points describe the editor, not extra transforms.
        // The 257 recorded samples already incorporate them, just as in Classic NP3 curves.
        // Retain the reserved-byte guard instead of accepting an unknown extended layout.
        supportedUnless(bytes.copyOfRange(49, 64).all { it == 0.toByte() }, "Unsupported NP3 tone curve metadata")
        return IntArray(PHOTO_FILTER_TONE_CURVE_POINT_COUNT) { index ->
            val offset = 64 + index * 2
            ((bytes[offset].unsigned() shl 8) or bytes[offset + 1].unsigned()).also {
                invalidUnless(it in 0..PHOTO_FILTER_TONE_CURVE_MAX_VALUE, "NP3 tone curve sample is out of range")
            }
        }
    }

    private fun parseColorGrading(bytes: ByteArray): Np3ColorGrading {
        supportedUnless(bytes.copyOfRange(12, 16).contentEquals(byteArrayOf(1, 1, 1, 0)) &&
            bytes[17].unsigned() == 1 && bytes[19].unsigned() == 1, "Unsupported NP3 color grading encoding")
        fun region(offset: Int): Np3ColorGradingRegion {
            supportedUnless(bytes[offset].unsigned() in 128..129, "Unsupported NP3 grading hue encoding")
            val hue = ((bytes[offset].unsigned() - 128) shl 8) or bytes[offset + 1].unsigned()
            val chroma = bytes[offset + 2].unsigned() - 128
            val brightness = bytes[offset + 3].unsigned() - 128
            invalidUnless(hue in 0..360 && chroma in -100..100 && brightness in -100..100,
                "NP3 color grading value is out of range")
            return Np3ColorGradingRegion(hue, chroma, brightness)
        }
        val blending = bytes[16].unsigned() - 128
        val balance = bytes[18].unsigned() - 128
        invalidUnless(blending in 0..100 && balance in -100..100,
            "NP3 color grading blend is out of range")
        val grading = Np3ColorGrading(region(0), region(4), region(8), blending, balance)
        // Hue, blending and balance have no effect while all regions are neutral. Canonicalize
        // them so formerly supported recipes keep their original parameters and snapshot bytes.
        return if (grading.isNeutral) Np3ColorGrading() else grading
    }

    private fun validateComment(bytes: ByteArray) {
        invalidUnless(bytes.isNotEmpty() && bytes.size % 2 == 0, "Invalid NP3 comment length")
        val end = bytes.indexOf(0)
        invalidUnless(end >= 0 && bytes.drop(end).all { it == 0.toByte() }, "Invalid NP3 comment terminator")
    }

    private fun Byte.unsigned() = toInt() and 255
    private fun Int.hex() = "0x" + toString(16)
    private fun invalidUnless(condition: Boolean, message: String) {
        if (!condition) fail(PhotoNp3Failure.INVALID, message)
    }
    private fun supportedUnless(condition: Boolean, message: String) {
        if (!condition) fail(PhotoNp3Failure.UNSUPPORTED, message)
    }
    private fun fail(reason: PhotoNp3Failure, message: String): Nothing = throw PhotoNp3Exception(reason, message)
}
