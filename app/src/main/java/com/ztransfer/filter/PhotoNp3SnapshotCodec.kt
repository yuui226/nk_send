package com.ztransfer.filter

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.MessageDigest

/** A bounded private recipe. Restoring never needs the document provider or the original file. */
internal object PhotoNp3SnapshotCodec {
    const val MAX_BYTES = 4096
    private const val MAGIC = 0x4e503353
    private const val FLEXIBLE_VERSION = 1
    private const val TYPED_VERSION = 2
    private const val CLASSIC_TYPE = 1

    fun isCustomId(id: String): Boolean = photoNp3RecipeKind(id) != null

    fun encode(preset: PhotoFilterPreset): ByteArray {
        val kind = requireNotNull(photoNp3RecipeKind(preset.id))
        require(preset.name.length in 1..256 && preset.name.none(Char::isISOControl))
        val parameters = preset.parameters
        require(when (kind) {
            PhotoNp3RecipeKind.FLEXIBLE -> parameters is Np3PhotoFilterParameters
            PhotoNp3RecipeKind.CLASSIC -> parameters is ClassicNp3PhotoFilterParameters
        }) { "NP3 recipe ID does not match its parameters" }
        val payload = ByteArrayOutputStream().also { buffer ->
            DataOutputStream(buffer).use { output ->
                output.writeInt(MAGIC)
                // Keep Flexible v1 byte-for-byte compatible with already saved recipes.
                output.writeInt(if (kind == PhotoNp3RecipeKind.FLEXIBLE) FLEXIBLE_VERSION else TYPED_VERSION)
                if (kind == PhotoNp3RecipeKind.CLASSIC) output.writeByte(CLASSIC_TYPE)
                output.writeUTF(preset.id)
                output.writeUTF(preset.name)
                when (parameters) {
                    is Np3PhotoFilterParameters -> {
                        listOf(parameters.contrast, parameters.highlights, parameters.shadows,
                            parameters.whites, parameters.blacks, parameters.saturation).forEach(output::writeInt)
                        parameters.colorBands.forEach { band ->
                            output.writeInt(band.hue)
                            output.writeInt(band.chroma)
                            output.writeInt(band.brightness)
                        }
                        output.writeCurve(parameters.toneCurve)
                    }
                    is ClassicNp3PhotoFilterParameters -> {
                        listOf(parameters.base.id, parameters.contrastQuarter, parameters.brightnessQuarter,
                            parameters.saturationQuarter, parameters.hueQuarter, parameters.filterEffect,
                            parameters.toningEffect, parameters.toningDensityQuarter, parameters.effectLevel)
                            .forEach(output::writeInt)
                        output.writeCurve(parameters.toneCurve)
                    }
                    else -> error("Not a photo NP3 recipe")
                }
            }
        }.toByteArray()
        return (payload + checksum(payload)).also { require(it.size <= MAX_BYTES) }
    }

    fun decode(bytes: ByteArray): PhotoFilterPreset {
        require(bytes.size in 40..MAX_BYTES)
        val payload = bytes.copyOfRange(0, bytes.size - 32)
        require(MessageDigest.isEqual(checksum(payload), bytes.copyOfRange(bytes.size - 32, bytes.size)))
        return DataInputStream(ByteArrayInputStream(payload)).use { input ->
            require(input.readInt() == MAGIC)
            val kind = when (input.readInt()) {
                FLEXIBLE_VERSION -> PhotoNp3RecipeKind.FLEXIBLE
                TYPED_VERSION -> {
                    require(input.readUnsignedByte() == CLASSIC_TYPE)
                    PhotoNp3RecipeKind.CLASSIC
                }
                else -> throw IllegalArgumentException("Unknown NP3 snapshot version")
            }
            val id = input.readUTF().also { require(photoNp3RecipeKind(it) == kind) }
            val name = input.readUTF().also {
                require(it.isNotBlank() && it.length <= 256 && it.none(Char::isISOControl))
            }
            val parameters = when (kind) {
                PhotoNp3RecipeKind.FLEXIBLE -> {
                    val controls = IntArray(6) { input.readInt() }
                    val bands = PHOTO_FILTER_COLOR_BAND_CENTERS.map { center ->
                        PhotoFilterColorBand(center, input.readInt(), input.readInt(), input.readInt())
                    }
                    Np3PhotoFilterParameters(controls[0], controls[1], controls[2], controls[3],
                        controls[4], controls[5], bands, input.readCurve())
                }
                PhotoNp3RecipeKind.CLASSIC -> {
                    val baseId = input.readInt()
                    val base = requireNotNull(ClassicNp3Style.entries.firstOrNull { it.id == baseId })
                    ClassicNp3PhotoFilterParameters(base, input.readInt(), input.readInt(), input.readInt(),
                        input.readInt(), input.readInt(), input.readInt(), input.readInt(), input.readInt(),
                        input.readCurve())
                }
            }
            require(input.read() == -1)
            PhotoFilterPreset(id, name, parameters)
        }
    }

    private fun DataOutputStream.writeCurve(curve: IntArray?) {
        writeInt(curve?.size ?: 0)
        curve?.forEach(::writeShort)
    }

    private fun DataInputStream.readCurve(): IntArray? {
        val size = readInt()
        require(size == 0 || size == PHOTO_FILTER_TONE_CURVE_POINT_COUNT)
        return if (size == 0) null else IntArray(size) { readUnsignedShort() }
    }

    private fun checksum(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
}
