package com.ztransfer.protocol

/**
 * NP3 0300 -> classic PictureControl DataSet. Wire fields/units: Nikon Z 30 MTP
 * specification 6.2.2.44 and 9.8 (also Z6 9.8, Z8/Z6III/Z50II/ZR 9.9).
 * Container mappings are independently checked against the six camera-exported pairs.
 * Only explicitly established base IDs are accepted; never truncate an NP3 ID to a PTP ID.
 */
internal fun NikonPictureControlFile.encodeClassicPictureControl(): ByteArray {
    require(version == "0300") { "Unsupported NP3 version: $version" }
    val allowedTags = (0x0100..0x1600 step 0x100).toSet() + setOf(2, 0x10100)
    require(fieldTags().all { it in allowedTags }) { "Unsupported NP3 fields" }
    fun field2(tag: Int): ByteArray = requireNotNull(field(tag)).also {
        require(it.size == 2) { "Invalid NP3 field 0x%04X".format(tag) }
    }
    fun value(tag: Int, encoding: Int): Int = field2(tag).let {
        require((it[1].toInt() and 255) == encoding) { "Unsupported NP3 field encoding" }
        it[0].toInt() and 255
    }
    fun fixed(tag: Int, first: Int, second: Int) {
        require(value(tag, second) == first) { "Unsupported NP3 adjustment 0x%04X".format(tag) }
    }
    val id = field2(0x0300).let { ((it[0].toInt() and 255) shl 8) or (it[1].toInt() and 255) }
    val base = when (id) {
        0x0001 -> 1
        0x03C2 -> 2
        // Also identified as VIVID in ExifTool Nikon.pm's PictureControlMode observations.
        0x00C3 -> 3
        0x080B -> 111
        0x080C -> 112
        else -> error("Unsupported NP3 base identifier: 0x%04X".format(id))
    }
    fixed(0x0400, 0, 0)
    fixed(0x0500, 255, 1)
    for (tag in 0x0F00..0x1300 step 0x100) fixed(tag, 255, 1)
    // These verified source formats use individual sharpening values, not automatic quick sharp.
    fixed(0x1400, 128, 1)
    fixed(0x0C00, 255, 0)
    fixed(0x0D00, 255, 0)
    fixed(0x0E00, 255, 4)
    val nameBytes = requireNotNull(field(0x0200))
    require(nameBytes.last() == 0.toByte() && name.length <= 19) { "Picture Control name exceeds 19 ASCII characters" }
    require(nameBytes.drop(name.length).all { it == 0.toByte() }) { "Invalid NP3 name padding" }
    val curve = field(2)?.let { NikonPictureControlToneCurve.parse(it).bytes() }
    val output = ByteArray(36 + (curve?.size ?: 0))
    output[0] = base.toByte()
    output[1] = (base shr 8).toByte()
    nameBytes.copyInto(output, 2)
    val effect = value(0x1500, 10)
    output[22] = if (base < 100) {
        require(effect == 255) { "Unexpected effect level on a standard Picture Control" }
        0
    } else {
        require(effect in 128..138) { "Invalid Picture Control effect level" }
        ((effect - 128) * 10).toByte()
    }
    // Off is intentional: On makes the camera IGNORE the three explicit NP3 sharpness values.
    output[23] = 0
    output[24] = 0
    fun scalar(tag: Int, offset: Int, range: IntRange, auto: Boolean = false,
               curveControlled: Boolean = false, unavailable: Boolean = false) {
        val raw = value(tag, 4)
        val decoded = when {
            raw == 1 && curveControlled && curve != null -> 0
            raw == 255 && unavailable -> 0
            raw == 0 && auto -> -128
            else -> (raw - 128).also { require(it in range) { "Unsupported NP3 value in 0x%04X".format(tag) } }
        }
        output[offset] = decoded.toByte()
    }
    scalar(0x0600, 25, -12..36)
    scalar(0x1600, 26, -20..20)
    scalar(0x0700, 27, -20..20)
    scalar(0x0800, 28, -12..12, auto = base < 100, curveControlled = true)
    scalar(0x0900, 29, if (base < 100) -6..6 else 0..0,
        curveControlled = true, unavailable = base >= 100)
    scalar(0x0A00, 30, -12..12, auto = base < 100)
    scalar(0x0B00, 31, if (base < 100) -12..12 else 0..0, unavailable = base >= 100)
    output[35] = if (curve == null) 0 else 1
    curve?.copyInto(output, 36)
    NikonPictureControlData.parseResponse(base, 0x2001, output)
    return output
}

/** Capability dataset in Nikon Z 30 section 9.9; reject a different model's layout. */
internal fun validatePictureControlCapabilities(dataset: ByteArray, capabilities: ByteArray) {
    require(capabilities.size == 28) { "Unsupported Picture Control capability layout" }
    require(capabilities.take(12).all { (it.toInt() and 255) in setOf(0, 1, 128, 129) }) {
        "Invalid Picture Control capabilities"
    }
    val offsets = listOf(22, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34)
    offsets.forEachIndexed { index, offset ->
        val capability = capabilities[index].toInt() and 255
        val value = dataset[offset].toInt()
        if (value == -128) require(capability and 1 != 0) { "Camera does not support this automatic adjustment" }
        else if (capability and 128 == 0) require(value == 0) { "Camera does not support this adjustment" }
    }
}
