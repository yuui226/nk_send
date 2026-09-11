package com.ztransfer.ui

import kotlin.test.*

class NativeSinglePhotoInputTest {
    private fun header(width: Long = 2048, height: Long = 2048): ByteArray = ByteArray(33).also { out ->
        intArrayOf(137,80,78,71,13,10,26,10).forEachIndexed { i,v -> out[i] = v.toByte() }
        fun put(offset: Int, value: Long) { repeat(4) { i -> out[offset + i] = (value ushr (24 - i * 8)).toByte() } }
        put(8,13); put(12,0x49484452); put(16,width); put(20,height)
    }
    @Test fun dimensionsAreCheckedUnsignedBeforeAnyDecode() {
        for (v in listOf(0L,2049L,Int.MAX_VALUE.toLong(),0xffffffffL)) {
            assertFalse(isBoundedSinglePhotoPng(header(width=v)))
            assertFalse(isBoundedSinglePhotoPng(header(height=v)))
        }
        assertTrue(isBoundedSinglePhotoPng(header(1,1)))
        assertTrue(isBoundedSinglePhotoPng(header()))
    }
    @Test fun signatureHeaderAndTruncationCannotBypassSizeGate() {
        val valid=header()
        for (length in 0..32) assertFalse(isBoundedSinglePhotoPng(valid.copyOf(length)))
        for (i in 0..15) {
            val broken=valid.copyOf(); broken[i]=(broken[i].toInt() xor 1).toByte()
            assertFalse(isBoundedSinglePhotoPng(broken))
        }
        assertFalse(isBoundedSinglePhotoPng(valid.copyOf(SINGLE_PHOTO_MAX_BYTES+1)))
    }
}
