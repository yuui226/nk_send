package com.ztransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** UINT16 selection descriptor; D200 verified against Z 30 V1.20 Wi-Fi probe v2. */
internal data class NikonPictureControlSelection(
    val writable: Boolean,
    val current: Int,
    val choices: List<Int>,
) {
    fun supportsSlot(slot: Int): Boolean = slot in NIKON_PICTURE_CONTROL_SLOTS && slot in choices

    // Some bodies may enumerate only registered entries. Never reserve the highest
    // visible/occupied entry: C9 must be part of the complete documented C1..C9 range.
    val confirmedLastCustomSlot: Int?
        get() = NIKON_PICTURE_CONTROL_C9.takeIf { (201..NIKON_PICTURE_CONTROL_C9).all(choices::contains) }

    companion object {
        fun parse(bytes: ByteArray, property: Int = 0xD200): NikonPictureControlSelection {
            require(property == 0xD200 || property == 0xD237) { "Unknown Picture Control selection property" }
            require(bytes.size >= 10) { "Truncated Picture Control descriptor" }
            val input = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            fun u16() = input.short.toInt() and 0xFFFF
            require(u16() == property && u16() == 0x0004) { "Unexpected Picture Control property/type" }
            val access = input.get().toInt() and 0xFF
            require(access in 0..1) { "Invalid Picture Control access flag" }
            u16() // factory default
            val current = u16()
            val form = input.get().toInt() and 0xFF
            val values = when (form) {
                0 -> emptyList()
                2 -> {
                    require(input.remaining() >= 2) { "Truncated Picture Control enumeration" }
                    val count = u16()
                    require(input.remaining() == count * 2) { "Invalid Picture Control enumeration length" }
                    List(count) { u16() }.also { require(it.distinct().size == it.size) }
                }
                else -> error("Unrecognized Picture Control descriptor form")
            }
            require(!input.hasRemaining()) { "Trailing Picture Control descriptor data" }
            return NikonPictureControlSelection(access == 1, current, values)
        }
    }
}
