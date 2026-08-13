package com.ztransfer.filter

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFilterRendererTest {
    @Test
    fun neutralProtectionRejectsNoiseAndPreservesEstablishedColor() {
        assertEquals(0f, PhotoFilterRenderer.neutralProtectionWeight(0f), 0f)
        assertEquals(
            0f,
            PhotoFilterRenderer.neutralProtectionWeight(
                PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_START,
            ),
            0f,
        )
        assertEquals(
            1f,
            PhotoFilterRenderer.neutralProtectionWeight(
                PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_END,
            ),
            0f,
        )
        assertEquals(1f, PhotoFilterRenderer.neutralProtectionWeight(1f), 0f)
    }

    @Test
    fun neutralProtectionTransitionsSmoothlyAndMonotonically() {
        val start = PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_START
        val end = PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_END
        val middle = (start + end) / 2f
        assertEquals(0.5f, PhotoFilterRenderer.neutralProtectionWeight(middle), 0.0001f)

        val weights = (0..16).map { step ->
            PhotoFilterRenderer.neutralProtectionWeight(start + (end - start) * step / 16f)
        }
        assertTrue(weights.zipWithNext().all { (left, right) -> left <= right })
    }

    @Test
    fun boundedHueNormalizationMatchesModuloDefinition() {
        listOf(-60f, -30f, -0.01f, 0f, 30f, 359.99f, 360f, 390f).forEach { hue ->
            val modulo = ((hue % 360f) + 360f) % 360f
            assertEquals(modulo, PhotoFilterRenderer.normalizeHue(hue), 0f)
        }
    }

    @Test
    fun branchBasedHslSecondaryComponentMatchesModuloDefinition() {
        (0..3_599).forEach { step ->
            val hue = step / 10f
            val section = hue / 60f
            val expected = 0.73f * (1f - abs(section % 2f - 1f))
            assertEquals(
                expected,
                PhotoFilterRenderer.hslSecondaryComponent(
                    section = section,
                    sector = section.toInt(),
                    chroma = 0.73f,
                ),
                0.000001f,
            )
        }
    }

    @Test
    fun exactLookupPreservesAlphaAndTransparentSourcePixels() {
        val mapped = 0x00123456
        assertEquals(
            0xff123456.toInt(),
            PhotoFilterRenderer.exactLookupOutputColor(0x00112233, mapped, false),
        )
        assertEquals(
            0x7f123456,
            PhotoFilterRenderer.exactLookupOutputColor(0x7f112233, mapped, true),
        )
        assertEquals(
            0x00112233,
            PhotoFilterRenderer.exactLookupOutputColor(0x00112233, mapped, true),
        )
    }
}
