package com.ztransfer.protocol

/** Layouts and commands confirmed by a read-only protocol exchange, never by trial writes. */
internal enum class NikonPictureControlFormat(val headerSize: Int) {
    CLASSIC_Z(36),
    LEGACY_V2(32);

    fun supportsSize(size: Int): Boolean = size == headerSize || size == headerSize + 578

    // The D5600-compatible two-argument protocol addresses D200 only.
    fun movieBank(movie: Boolean): Boolean = movie && this == CLASSIC_Z
    fun selectionProperty(movie: Boolean): Int = if (movieBank(movie)) 0xD237 else 0xD200
    fun params(movie: Boolean, vararg values: Int): IntArray =
        if (this == CLASSIC_Z) values + intArrayOf(if (movie) 1 else 0) else values
    val writeOperation: Int get() = if (this == CLASSIC_Z) 0x90CD else 0x940E
    fun writeParams(movie: Boolean, slot: Int, modified: Int): IntArray =
        if (this == CLASSIC_Z) params(movie, slot, modified)
        // SetPicCtrlDataEx explicitly selects V2 (with clarity). The optional movie
        // argument is omitted for the photo/shared bank; unverified movie banks are blocked.
        else intArrayOf(slot, modified, 1)
}

internal class PictureControlPresetUnsupportedException(detail: String) : IllegalArgumentException(detail)
