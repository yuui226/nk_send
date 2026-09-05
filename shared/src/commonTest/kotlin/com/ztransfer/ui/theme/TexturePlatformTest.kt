package com.ztransfer.ui.theme

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class TexturePlatformTest {
    @Test fun negativeSeedsUseFloorModuloNotRemainder() {
        assertEquals(23, textureFloorMod(-1, 24))
        assertEquals(4, textureFloorMod(Int.MIN_VALUE, 12))
        assertEquals(0, textureFloorMod(Int.MIN_VALUE, 4))
        assertEquals(7, textureFloorMod(Int.MAX_VALUE, 24))
        assertEquals(0, textureFloorMod(0, 24))
        assertFailsWith<IllegalArgumentException> { textureFloorMod(1, 0) }
    }

    @Test fun rgbaEncodingPreservesStraightAlphaAndAllChannels() {
        assertContentEquals(byteArrayOf(0x12, 0x34, 0x56, 0x7f, -1, -128, 0, -1, 0x11, 0x22, 0x33, 0),
            textureRgbaBytes(intArrayOf(0x7f123456, 0xffff8000.toInt(), 0x00112233), 3, 1))
    }

    @Test fun rgbaEncodingRejectsInvalidDimensionsBeforeAllocating() {
        assertFailsWith<IllegalArgumentException> { textureRgbaBytes(intArrayOf(), 0, 1) }
        assertFailsWith<IllegalArgumentException> { textureRgbaBytes(intArrayOf(0), 2, 1) }
        assertFailsWith<IllegalArgumentException> { textureRgbaBytes(intArrayOf(0), Int.MAX_VALUE, Int.MAX_VALUE) }
    }

    @Test fun cacheLockSupportsTheOriginalReentrantMonitorContract() {
        val lock = TextureCacheLock()
        assertEquals(42, lock.withLock { lock.withLock { 42 } })
    }

    @Test fun cacheLockReleasesAfterAnException() {
        val lock = TextureCacheLock()
        assertFailsWith<IllegalStateException> { lock.withLock { error("generation failed") } }
        assertEquals(17, lock.withLock { 17 })
    }
}
