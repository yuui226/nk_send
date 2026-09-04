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

    @Test
    fun ncpAndNp3RenderersMatchFixedArgbVectors() {
        val source = intArrayOf(
            0x00112233,
            0x80112233.toInt(),
            0xff000000.toInt(),
            0xffffffff.toInt(),
            0xff808080.toInt(),
            0xffff0000.toInt(),
            0xff00ff00.toInt(),
            0xff0000ff.toInt(),
            0xffffc090.toInt(),
            0xff806070.toInt(),
        )
        val toneCurve = IntArray(PHOTO_FILTER_TONE_CURVE_POINT_COUNT) { index ->
            (index.toLong() * index * PHOTO_FILTER_TONE_CURVE_MAX_VALUE /
                (PHOTO_FILTER_TONE_CURVE_POINT_COUNT - 1).let { it.toLong() * it }).toInt()
        }
        val ncp = PhotoFilterSelection(
            preset = PhotoFilterPreset(
                id = "fixed-ncp",
                name = "Fixed NCP",
                parameters = NcpPhotoFilterParameters(
                    saturationStep = 2,
                    hueStep = -1,
                    toneCurve = toneCurve,
                ),
            ),
            intensityPercent = 72,
        )
        val bands = PHOTO_FILTER_COLOR_BAND_CENTERS.mapIndexed { index, center ->
            PhotoFilterColorBand(
                centerDegrees = center,
                hue = listOf(15, -10, 20, -25, 30, -35, 40, -45)[index],
                chroma = listOf(20, 30, -20, 40, -30, 50, -40, 10)[index],
                brightness = listOf(-10, 15, 20, -15, 25, -20, 10, 5)[index],
            )
        }
        val np3WithCurve = PhotoFilterSelection(
            preset = PhotoFilterPreset(
                id = "fixed-np3-curve",
                name = "Fixed NP3 Curve",
                parameters = Np3PhotoFilterParameters(
                    contrast = 20,
                    highlights = -30,
                    shadows = 25,
                    whites = 10,
                    blacks = -15,
                    saturation = 18,
                    colorBands = bands,
                    toneCurve = toneCurve,
                ),
            ),
            intensityPercent = 100,
        )
        val np3WithoutCurve = PhotoFilterSelection(
            preset = PhotoFilterPreset(
                id = "fixed-np3-tonal",
                name = "Fixed NP3 Tonal",
                parameters = Np3PhotoFilterParameters(
                    contrast = 20,
                    highlights = -30,
                    shadows = 25,
                    whites = 10,
                    blacks = -15,
                    saturation = 18,
                    colorBands = bands,
                ),
            ),
            intensityPercent = 72,
        )

        assertEquals(
            "00112233,80050e14,ff000000,ffffffff,ff525252,ffa3000f,ff0fa300," +
                "ff000fa3,ffff8551,ff503646",
            PhotoFilterRenderer.renderArgbPixels(source, ncp, preserveAlpha = true).hexVector(),
        )
        assertEquals(
            "00112233,80020508,ff000000,ffffffff,ff404040,ff750900,ff0e7100," +
                "ff00136c,ffff934c,ff3b2835",
            PhotoFilterRenderer.renderArgbPixels(
                source,
                np3WithCurve,
                preserveAlpha = true,
            ).hexVector(),
        )
        assertEquals(
            "00112233,800d2134,ff000000,ffffffff,ff7f7f7f,fff70d00,ff16f300," +
                "ff001ef1,ffffc094,ff855d76",
            PhotoFilterRenderer.renderArgbPixels(
                source,
                np3WithoutCurve,
                preserveAlpha = true,
            ).hexVector(),
        )
    }

    private fun IntArray.hexVector(): String =
        joinToString(",") { value -> value.toUInt().toString(16).padStart(8, '0') }
}
