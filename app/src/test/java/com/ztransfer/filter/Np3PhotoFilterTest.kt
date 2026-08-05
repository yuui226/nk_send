package com.ztransfer.filter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Np3PhotoFilterTest {
    @Test
    fun simplePresetParsesAllSupportedControls() {
        val bytes = simpleNp3("CLR TEALOR 01A")
        bytes[0x110] = setting(18)
        bytes[0x11a] = setting(-12)
        bytes[0x142] = setting(25)
        bytes[0x14c] = setting(-30)
        bytes[0x14d] = setting(40)
        bytes[0x14e] = setting(8)

        val preset = Np3PhotoFilterParser.parse(bytes)

        assertEquals("CLR TEALOR 01A", preset.name)
        assertEquals(18, preset.contrast)
        assertEquals(-12, preset.highlights)
        assertEquals(25, preset.saturation)
        assertEquals(-30, preset.colorBands.first().hue)
        assertEquals(40, preset.colorBands.first().chroma)
        assertEquals(8, preset.colorBands.first().brightness)
        assertEquals(8, preset.colorBands.size)
    }

    @Test
    fun contentHashProvidesStablePrivateIdentity() {
        val first = Np3PhotoFilterParser.parse(simpleNp3("Preset"))
        val same = Np3PhotoFilterParser.parse(simpleNp3("Preset"))
        val changedBytes = simpleNp3("Preset").also { it[0x110] = setting(1) }
        val changed = Np3PhotoFilterParser.parse(changedBytes)

        assertEquals(first.id, same.id)
        assertNotEquals(first.id, changed.id)
        assertTrue(first.id.matches(Regex("[0-9a-f]{64}")))
    }

    @Test
    fun customCurveIsRejectedInsteadOfSilentlyLosingIt() {
        val error = runCatching {
            Np3PhotoFilterParser.parse(simpleNp3("Curve").copyOf(978))
        }.exceptionOrNull() as Np3FilterException

        assertEquals(Np3FilterRejection.CUSTOM_TONE_CURVE, error.rejection)
    }

    @Test
    fun threeWayColorGradingIsRejectedInsteadOfSilentlyLosingIt() {
        val bytes = simpleNp3("Grading")
        bytes[0x172] = setting(1)

        val error = runCatching {
            Np3PhotoFilterParser.parse(bytes)
        }.exceptionOrNull() as Np3FilterException

        assertEquals(Np3FilterRejection.COLOR_GRADING, error.rejection)
    }

    @Test
    fun malformedFileIsRejected() {
        val error = runCatching {
            Np3PhotoFilterParser.parse(ByteArray(392))
        }.exceptionOrNull() as Np3FilterException

        assertEquals(Np3FilterRejection.INVALID_FILE, error.rejection)
    }

    @Test
    fun colorBandInterpolationWrapsSmoothlyAcrossRed() {
        val centers = NP3_COLOR_BAND_CENTERS.toList()
        val nearEnd = adjacentColorBandWeights(350f, centers)
        val nearStart = adjacentColorBandWeights(10f, centers)

        assertEquals(7, nearEnd.first)
        assertEquals(0, nearEnd.second)
        assertEquals(0, nearStart.first)
        assertEquals(1, nearStart.second)
        assertTrue(nearEnd.third in 0f..1f)
        assertTrue(nearStart.third in 0f..1f)
    }

    @Test
    fun intensityIsAlwaysSafeForRenderingAndFileIdentity() {
        assertEquals(0, normalizePhotoFilterIntensity(-1))
        assertEquals(72, normalizePhotoFilterIntensity(72))
        assertEquals(100, normalizePhotoFilterIntensity(101))
    }

    private fun simpleNp3(name: String): ByteArray {
        val bytes = ByteArray(392) { 0x80.toByte() }
        bytes[0] = 'N'.code.toByte()
        bytes[1] = 'C'.code.toByte()
        bytes[2] = 'P'.code.toByte()
        bytes[3] = 0
        val encoded = name.toByteArray(Charsets.US_ASCII).take(19).toByteArray()
        encoded.copyInto(bytes, destinationOffset = 0x18)
        bytes[0x18 + encoded.size] = 0
        bytes[0x187] = 0
        return bytes
    }

    private fun setting(value: Int): Byte = (value + 0x80).toByte()
}
