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
    private const val VERSION = 1
    private val presetId = Regex("np3:[a-f0-9]{64}:np3-srgb-v1")

    fun isCustomId(id: String): Boolean = presetId.matches(id)

    fun encode(preset: PhotoFilterPreset): ByteArray {
        require(isCustomId(preset.id))
        require(preset.name.length in 1..256 && preset.name.none(Char::isISOControl))
        val parameters = preset.parameters as? Np3PhotoFilterParameters
            ?: throw IllegalArgumentException("Not a photo NP3 recipe")
        val payload = ByteArrayOutputStream().also { buffer ->
            DataOutputStream(buffer).use { output ->
                output.writeInt(MAGIC)
                output.writeInt(VERSION)
                output.writeUTF(preset.id)
                output.writeUTF(preset.name)
                listOf(parameters.contrast, parameters.highlights, parameters.shadows,
                    parameters.whites, parameters.blacks, parameters.saturation).forEach(output::writeInt)
                parameters.colorBands.forEach { band ->
                    output.writeInt(band.hue)
                    output.writeInt(band.chroma)
                    output.writeInt(band.brightness)
                }
                val curve = parameters.toneCurve
                output.writeInt(curve?.size ?: 0)
                curve?.forEach(output::writeShort)
            }
        }.toByteArray()
        return (payload + checksum(payload)).also { require(it.size <= MAX_BYTES) }
    }

    fun decode(bytes: ByteArray): PhotoFilterPreset {
        require(bytes.size in 40..MAX_BYTES)
        val payload = bytes.copyOfRange(0, bytes.size - 32)
        require(MessageDigest.isEqual(checksum(payload), bytes.copyOfRange(bytes.size - 32, bytes.size)))
        return DataInputStream(ByteArrayInputStream(payload)).use { input ->
            require(input.readInt() == MAGIC && input.readInt() == VERSION)
            val id = input.readUTF().also { require(isCustomId(it)) }
            val name = input.readUTF().also {
                require(it.isNotBlank() && it.length <= 256 && it.none(Char::isISOControl))
            }
            val controls = IntArray(6) { input.readInt() }
            val bands = PHOTO_FILTER_COLOR_BAND_CENTERS.map { center ->
                PhotoFilterColorBand(center, input.readInt(), input.readInt(), input.readInt())
            }
            val curveSize = input.readInt()
            require(curveSize == 0 || curveSize == PHOTO_FILTER_TONE_CURVE_POINT_COUNT)
            val curve = if (curveSize == 0) null else IntArray(curveSize) { input.readUnsignedShort() }
            require(input.read() == -1)
            PhotoFilterPreset(id, name, Np3PhotoFilterParameters(
                controls[0], controls[1], controls[2], controls[3], controls[4], controls[5], bands, curve,
            ))
        }
    }

    private fun checksum(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
}
