package com.ztransfer.filter

import kotlin.math.abs
import org.junit.Assert.*
import org.junit.Test

class Np3ColorGradingTest {
    @Test fun inactiveRegionsDoNotAddAProcessingPass() {
        assertNull(CompiledNp3ColorGrading.compile(Np3ColorGrading()))
        assertNull(CompiledNp3ColorGrading.compile(Np3ColorGrading(
            highlights = Np3ColorGradingRegion(hue = 360),
            midtones = Np3ColorGradingRegion(hue = 120),
            shadows = Np3ColorGradingRegion(hue = 240), blending = 100, balance = -100,
        )))
    }

    @Test fun threeRegionsTintNeutralPixelsInTheirRespectiveLuminanceRanges() {
        val grading = Np3ColorGrading(
            highlights = Np3ColorGradingRegion(0, 80),
            midtones = Np3ColorGradingRegion(120, 80),
            shadows = Np3ColorGradingRegion(240, 80), blending = 0,
        )
        val effect = checkNotNull(CompiledNp3ColorGrading.compile(grading))
        val shadow = effect.apply(0x202020)
        val mid = effect.apply(0x808080)
        val highlight = effect.apply(0xe0e0e0)
        assertTrue(b(shadow) > r(shadow) && b(shadow) > g(shadow))
        assertTrue(g(mid) > r(mid) && g(mid) > b(mid))
        assertTrue(r(highlight) > g(highlight) && r(highlight) > b(highlight))
        assertEquals(0, effect.apply(0))
        assertEquals(0xffffff, effect.apply(0xffffff))
    }

    @Test fun balanceFavorsHighlightsOrShadowsAndBlendingChangesTransition() {
        val base = Np3ColorGrading(
            highlights = Np3ColorGradingRegion(0, 80),
            shadows = Np3ColorGradingRegion(240, 80), blending = 0,
        )
        val warm = apply(base.copy(balance = 100), 0x808080)
        val cool = apply(base.copy(balance = -100), 0x808080)
        assertTrue(r(warm) > b(warm))
        assertTrue(b(cool) > r(cool))
        assertNotEquals(apply(base, 0x606060), apply(base.copy(blending = 100), 0x606060))
    }

    @Test fun brightnessWorksWithoutChromaAndChromaPreservesLuminanceWithinRounding() {
        for (region in 0..2) {
            fun recipe(value: Int): Np3ColorGrading {
                val control = Np3ColorGradingRegion(brightness = value)
                return when (region) {
                    0 -> Np3ColorGrading(shadows = control)
                    1 -> Np3ColorGrading(midtones = control)
                    else -> Np3ColorGrading(highlights = control)
                }
            }
            val gray = listOf(0x303030, 0x808080, 0xd0d0d0)[region]
            val brighter = apply(recipe(100), gray)
            val darker = apply(recipe(-100), gray)
            assertTrue(r(brighter) > r(gray))
            assertTrue(r(darker) < r(gray))
            assertEquals(r(brighter), g(brighter))
            assertEquals(g(brighter), b(brighter))
        }
        val colors = java.util.Random(53).let { random -> IntArray(4096) { random.nextInt() and 0xffffff } }
        val effect = checkNotNull(CompiledNp3ColorGrading.compile(Np3ColorGrading(
            highlights = Np3ColorGradingRegion(45, 100),
            midtones = Np3ColorGradingRegion(120, -100),
            shadows = Np3ColorGradingRegion(240, 100), blending = 100, balance = 100,
        )))
        for (color in colors) assertTrue(abs(luma(color) - luma(effect.apply(color))) <= 1f)
    }

    @Test fun continuousGrayRampDoesNotDevelopBandBoundaries() {
        for (blend in listOf(0, 50, 100)) for (balance in listOf(-100, 0, 100)) {
            val effect = checkNotNull(CompiledNp3ColorGrading.compile(Np3ColorGrading(
                highlights = Np3ColorGradingRegion(0, 100, 50),
                midtones = Np3ColorGradingRegion(120, 100, -50),
                shadows = Np3ColorGradingRegion(240, 100, 50), blending = blend, balance = balance,
            )))
            val ramp = (0..255).map { effect.apply(it * 0x010101) }
            for ((before, after) in ramp.zipWithNext()) {
                assertTrue(abs(r(before) - r(after)) <= 8)
                assertTrue(abs(g(before) - g(after)) <= 8)
                assertTrue(abs(b(before) - b(after)) <= 8)
            }
        }
    }

    @Test fun hueWrapKeepsTheSameColor() {
        val source = 0x7a8496
        val a = Np3ColorGrading(midtones = Np3ColorGradingRegion(0, 100, 100))
        val b = a.copy(midtones = a.midtones.copy(hue = 360))
        assertEquals(apply(a, source), apply(b, source))
    }

    private fun apply(grading: Np3ColorGrading, rgb: Int) =
        checkNotNull(CompiledNp3ColorGrading.compile(grading)).apply(rgb)

    private fun r(rgb: Int) = rgb ushr 16 and 255
    private fun g(rgb: Int) = rgb ushr 8 and 255
    private fun b(rgb: Int) = rgb and 255
    private fun luma(rgb: Int) = r(rgb) * 0.2126f + g(rgb) * 0.7152f + b(rgb) * 0.0722f
}
