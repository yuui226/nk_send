package com.ztransfer.protocol

internal class PictureControlMovieBankUnsupportedException :
    IllegalStateException("The separate/unknown movie Picture Control bank is not verified")

/** V2 cameras with a separate movie property need their movie protocol verified separately. */
internal data class NikonPictureControlProtocol(
    val format: NikonPictureControlFormat,
    val supportsMovie: Boolean,
    val cacheable: Boolean = true,
) {
    fun requireMode(movie: Boolean) {
        if (movie && !supportsMovie) throw PictureControlMovieBankUnsupportedException()
    }
}

/** One complete exchange, with diagnostics even when the transport throws before responding. */
internal suspend fun pictureControlExchange(
    transport: PictureControlTransport, sessionCheck: () -> Boolean, log: ((String) -> Unit)?,
    code: Int, params: IntArray, data: ByteArray? = null,
): Pair<Int, ByteArray?> {
    check(sessionCheck()) { "Camera session changed" }
    log?.invoke(if (data == null) "out op=0x%04X params=%s".format(code, params.joinToString())
        else "out op=0x%04X params=%s bytes=%d data=%s".format(code,
            params.joinToString(), data.size, data.joinToString("") { "%02x".format(it) }))
    val response = transport.exchange(code, params, data)
    log?.invoke("in op=0x%04X params=%s rc=0x%04X bytes=%d data=%s".format(code, params.joinToString(), response.first,
        response.second?.size ?: 0, response.second?.joinToString("") { "%02x".format(it) }.orEmpty()))
    return response
}

/**
 * Read-only protocol discovery, once per connection. A model name is not a capability.
 * Read STANDARD, never a possibly empty custom slot, and never send a trial write/delete.
 * Busy, disconnects, corrupted data and old 31/609-byte V1 layouts must not trigger retries
 * using another write protocol. V2 is accepted only after a valid two-argument response.
 */
internal suspend fun discoverPictureControlProtocol(
    operations: Set<Int>, properties: Set<Int>, transport: PictureControlTransport,
    sessionCheck: () -> Boolean, movie: Boolean, log: ((String) -> Unit)? = null,
): NikonPictureControlProtocol {
    check(0x90CC in operations) { "Picture Control reading is unavailable" }
    suspend fun read(vararg params: Int) = pictureControlExchange(transport, sessionCheck, log, 0x90CC, params)
    fun validate(response: Pair<Int, ByteArray?>, format: NikonPictureControlFormat) {
        val standard = NikonPictureControlData.parseResponse(1, response.first, response.second, format)
        check(!standard.isEmpty && standard.baseItem == 1) { "Unexpected STANDARD Picture Control response" }
    }
    // Stay in the requested bank: movie access must not depend on photo parameters
    // being readable while the camera is in movie Live View (and vice versa).
    val first = read(1, 0, if (movie) 1 else 0)
    if (first.first == 0x2001) {
        if (NikonPictureControlFormat.CLASSIC_Z.supportsSize(first.second?.size ?: 0)) {
            validate(first, NikonPictureControlFormat.CLASSIC_Z)
            return NikonPictureControlProtocol(NikonPictureControlFormat.CLASSIC_Z, supportsMovie = true)
        }
        // Some old bodies ignore an extra parameter. Validate their V2 data before
        // confirming that they also accept the documented two-argument command.
        validate(first, NikonPictureControlFormat.LEGACY_V2)
    } else {
        check(first.first == 0x2006 || first.first == 0x201D) {
            "Picture Control discovery failed: 0x%04X".format(first.first)
        }
    }
    val legacy = read(1, 0)
    validate(legacy, NikonPictureControlFormat.LEGACY_V2)
    // A missing advertisement alone does not prove that a movie bank is absent.
    // Only an explicit DeviceProp_Not_Supported response confirms the shared bank.
    if (0xD237 !in properties && 0x1014 in operations) {
        val movieProperty = pictureControlExchange(transport, sessionCheck, log, 0x1014, intArrayOf(0xD237))
        if (movieProperty.first == 0x200A) return NikonPictureControlProtocol(
            NikonPictureControlFormat.LEGACY_V2, supportsMovie = true)
        val confirmedSeparateBank = movieProperty.first == 0x2001 && runCatching {
            NikonPictureControlSelection.parse(requireNotNull(movieProperty.second), 0xD237)
        }.isSuccess
        return NikonPictureControlProtocol(NikonPictureControlFormat.LEGACY_V2,
            supportsMovie = false, cacheable = confirmedSeparateBank)
    }
    // A separate/unknown movie bank must never silently map to D200.
    return NikonPictureControlProtocol(NikonPictureControlFormat.LEGACY_V2,
        supportsMovie = false, cacheable = 0xD237 in properties)
}
