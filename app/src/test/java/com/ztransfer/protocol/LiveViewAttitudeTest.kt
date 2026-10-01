package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class LiveViewAttitudeTest {
    private fun header(roll: Long, pitch: Long): ByteArray = ByteArray(512).also {
        it[1] = 1; it[10] = 2
        fun put(offset: Int, value: Long) { repeat(4) { i -> it[offset + i] = (value ushr (24 - i * 8)).toByte() } }
        put(404, roll); put(408, pitch)
    }
    @Test fun decodesCapturedZ30Poses() {
        val samples = listOf(
            Triple(0x01676677L, 0x0166ffb3L, -1.000f),
            Triple(0x01677341L, 0x000f553fL, 15.333f),
            Triple(0x0163f3c2L, 0x015befc2L, -12.063f),
            Triple(0x0011f5c9L, 0x0164f252L, -3.053f))
        samples.forEach { (roll, pitch, expected) ->
            val value = requireNotNull(parseCompactLiveViewAttitude(header(roll, pitch), 512))
            assertEquals(expected, value.pitch, 0.01f)
        }
        assertEquals(17.96f, parseCompactLiveViewAttitude(header(0x0011f5c9, 0x0164f252), 512)!!.roll, 0.01f)
    }
    private fun portraitHeader(roll: Long, pitch: Long): ByteArray = header(roll, 0xFFFFFFFFL).also {
        repeat(4) { i -> it[412 + i] = (pitch ushr (24 - i * 8)).toByte() }
    }
    @Test fun portraitUsesAlternateAxisOnlyWhenLandscapeAxisIsExplicitlyUnavailable() {
        val samples = listOf(
            Triple(0x00591980L, 0x01670000L, -1f),
            Triple(0x0055cc3cL, 0x0013c2ceL, 19.761f),
            Triple(0x005a4cceL, 0x0153c000L, -20.25f))
        samples.forEach { (roll, pitch, expected) ->
            val value = requireNotNull(parseCompactLiveViewAttitude(portraitHeader(roll, pitch), 512))
            assertEquals(expected, value.pitch, 0.01f)
            assertEquals(roll / 65536f, value.roll, 0.001f)
        }
        assertNull(parseCompactLiveViewAttitude(portraitHeader(90L * 65536, 0xFFFFFFFFL), 512))
        assertNull(parseCompactLiveViewAttitude(portraitHeader(0, 65536), 512))
        val invalid = portraitHeader(90L * 65536, 65536)
        invalid[408] = 0x7f // Not the explicit unavailable marker: no alternate-axis fallback.
        assertNull(parseCompactLiveViewAttitude(invalid, 512))
    }
    @Test fun reversePortraitUses180DegreeNeutralAndInvertedPitch() {
        val samples = listOf(
            Triple(0x010f0cb7L, 0x00b33351L, 0.80f),
            Triple(0x010aa67dL, 0x009c768dL, 23.537f),
            Triple(0x010e0cdcL, 0x00c30000L, -15f))
        samples.forEach { (roll, pitch, expected) ->
            val value = requireNotNull(parseCompactLiveViewAttitude(portraitHeader(roll, pitch), 512))
            assertEquals(expected, value.pitch, 0.01f)
            assertEquals(roll / 65536f - 360f, value.roll, 0.001f)
        }
        assertEquals(0f, parseCompactLiveViewAttitude(portraitHeader(270L * 65536, 180L * 65536), 512)!!.pitch, 0f)
        assertNull(parseCompactLiveViewAttitude(portraitHeader(270L * 65536, 0xFFFFFFFFL), 512))
        assertNull(parseCompactLiveViewAttitude(portraitHeader(270L * 65536, 0), 512))
    }
    @Test fun invertedLandscapeUsesPrimaryAxisWith180DegreeNeutral() {
        fun inverted(roll: Long, pitch: Long) = header(roll, pitch).also {
            repeat(4) { i -> it[412 + i] = 0xFF.toByte() }
        }
        val samples = listOf(
            Triple(0x00b6f33fL, 0x00b34002L, 0.75f),
            Triple(0x00b34cd9L, 0x00a30ccfL, 16.95f),
            Triple(0x00b2f33fL, 0x00ca3334L, -22.2f))
        samples.forEach { (roll, pitch, expected) ->
            val value = requireNotNull(parseCompactLiveViewAttitude(inverted(roll, pitch), 512))
            assertEquals(expected, value.pitch, 0.01f)
        }
        assertEquals(0f, parseCompactLiveViewAttitude(inverted(180L * 65536, 180L * 65536), 512)!!.pitch, 0f)
        assertNull(parseCompactLiveViewAttitude(inverted(180L * 65536, 0xFFFFFFFFL), 512))
        assertNull(parseCompactLiveViewAttitude(inverted(180L * 65536, 0), 512))
    }
    @Test fun unknownLayoutsAndReservedValuesDoNotCreateFalseLevel() {
        assertNull(parseCompactLiveViewAttitude(header(0, 0), 512))
        assertNull(parseCompactLiveViewAttitude(header(0xffffffffL, 0), 512))
        assertNull(parseCompactLiveViewAttitude(header(1, 120L * 65536), 512))
        assertNull(parseCompactLiveViewAttitude(header(1, 1), 1024))
        assertNull(parseCompactLiveViewAttitude(header(1, 1).also { it[1] = 2 }, 512))
        assertNull(parseCompactLiveViewAttitude(ByteArray(100), 512))
        assertNotNull(parseCompactLiveViewAttitude(header(0, 65536), 512))
    }
}
