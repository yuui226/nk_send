package com.ztransfer.protocol

internal fun NikonPictureControlFile.encodePictureControl(format: NikonPictureControlFormat): ByteArray {
    val classic = encodeClassicPictureControl()
    return if (format == NikonPictureControlFormat.CLASSIC_Z) classic else encodeV2PictureControl(classic)
}

/**
 * D5600 MTP 7.4.3 / MAID second-generation data: 32-byte header, quarter-step
 * adjustments, optional 578-byte curve. The three original NP2/NP3 preset pairs
 * (phpstone.com/nikon-picture-control) have identical tag 0x02 curves, including
 * the 64-byte header and all 257 big-endian samples. No curve resampling is needed.
 * Newer adjustments without a V2 equivalent must not be silently discarded.
 */
internal fun encodeV2PictureControl(classic: ByteArray): ByteArray {
    val parsed = NikonPictureControlData.parseResponse(201, 0x2001, classic)
    fun supported(condition: Boolean, detail: String) {
        if (!condition) throw PictureControlPresetUnsupportedException(detail)
    }
    supported(!parsed.isEmpty && parsed.baseItem in 1..3, "V2 cannot use this NP3 base")
    supported(classic[25].toInt() in 0..36, "V2 cannot use negative sharpening")
    supported(classic[26] == 0.toByte(), "V2 has no mid-range sharpening")
    supported(listOf(22, 23, 24, 32, 33, 34).all { classic[it] == 0.toByte() },
        "NP3 contains adjustments without a V2 equivalent")
    val output = ByteArray(32 + (parsed.curve?.bytes()?.size ?: 0))
    output[0] = parsed.baseItem.toByte()
    output[1] = 0 // Color; the accepted NP3 base mappings above are all color controls.
    output[2] = 1 // Custom, regardless of which C1–C9 slot will receive it.
    classic.copyInto(output, 3, 2, 22)
    output[23] = 0 // Custom controls require individual adjustments, not QuickAdjust.
    output[24] = 0
    output[25] = classic[30] // Saturation
    output[26] = classic[31] // Hue
    output[27] = classic[25] // Sharpening
    output[28] = classic[28] // Contrast
    output[29] = classic[29] // Brightness
    output[30] = classic[27] // Clarity
    output[31] = classic[35]
    parsed.curve?.bytes()?.copyInto(output, 32)
    NikonPictureControlData.parseResponse(201, 0x2001, output, NikonPictureControlFormat.LEGACY_V2)
    return output
}

/** D5600 MTP 6.2.2.15: a validity byte, seven capabilities and 31 default values. */
internal fun validateV2PictureControlCapabilities(dataset: ByteArray, capabilities: ByteArray) {
    validateV2PictureControlCapabilityLayout(capabilities)
    listOf(24, 27, 30, 28, 29, 25, 26).forEachIndexed { index, offset ->
        val capability = capabilities[index + 1].toInt() and 255
        val value = dataset[offset].toInt()
        val supported = if (value == -128) capability and 1 != 0 else capability and 128 != 0 || value == 0
        if (!supported) throw PictureControlPresetUnsupportedException("Camera does not support adjustment at $offset")
    }
}

internal fun validateV2PictureControlCapabilityLayout(capabilities: ByteArray) {
    require(capabilities.size == 39 && capabilities[0] == 1.toByte()) {
        "Unsupported V2 Picture Control capability layout"
    }
    require(capabilities.slice(1..7).all { (it.toInt() and 255) in setOf(0, 1, 128, 129) }) {
        "Invalid V2 Picture Control capabilities"
    }
}
