package com.ztransfer.filter

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the common preview pixel loop and exact-color export loop without Android bitmaps. */
class ClassicNp3RendererTest {
    private val methods = PhotoFilterRenderer.javaClass.declaredMethods
    private val compile = methods.single { it.name == "compileFilter" }.apply { isAccessible = true }
    private val direct = methods.single { it.name == "filterPixelRange" }.apply { isAccessible = true }
    private val memoized = methods.single { it.name == "applyExactRgbMemoRange" }.apply { isAccessible = true }
    private val notCancelled = { false }

    @Test fun standardNeutralAndAutoControlsPreserveDevelopedSource() {
        val input = colors()
        assertArrayEquals(input, render(parameters(), input))
        assertArrayEquals(input, render(parameters(ClassicNp3Style.AUTO).copy(
            contrastQuarter = CLASSIC_PHOTO_FILTER_AUTO,
            saturationQuarter = CLASSIC_PHOTO_FILTER_AUTO,
        ), input))
    }

    @Test fun fractionalColorControlsAreNotRoundedToWholeSteps() {
        val input = intArrayOf(0xffb65c32.toInt(), 0xff34ae91.toInt(), 0xff675bb8.toInt())
        val neutral = render(parameters(), input)
        assertTrue(!neutral.contentEquals(render(parameters().copy(hueQuarter = 1), input)))
        assertTrue(!neutral.contentEquals(render(parameters().copy(saturationQuarter = 1), input)))
        assertTrue(!neutral.contentEquals(render(parameters().copy(brightnessQuarter = 1), input)))
        assertTrue(!neutral.contentEquals(render(parameters().copy(contrastQuarter = 1), input)))
    }

    @Test fun recordedCurveOwnsContrastAndBrightnessAndUsesItsRecordedSamplesOnce() {
        val curve = IntArray(257) { 4096 + it * 96 }
        val input = intArrayOf(0xff000000.toInt(), 0xff808080.toInt(), 0xffffffff.toInt())
        val original = parameters().copy(toneCurve = curve)
        val adjusted = original.copy(contrastQuarter = 12, brightnessQuarter = -6)
        assertArrayEquals(render(original, input), render(adjusted, input))
        val output = render(original, input)
        assertEquals(32, output[0] and 255)
        assertEquals(223, output[2] and 255)
    }

    @Test fun monochromeFiltersRetainNeutralGrayAndChangeColoredLuminance() {
        val gray = intArrayOf(0xff202020.toInt(), 0xff808080.toInt(), 0xffeeeeee.toInt())
        for (filter in 0..4) {
            assertArrayEquals(gray, render(parameters(ClassicNp3Style.MONOCHROME).copy(filterEffect = filter), gray))
        }
        val input = intArrayOf(0xffff0000.toInt(), 0xff00ff00.toInt(), 0xff0000ff.toInt())
        val baseline = render(parameters(ClassicNp3Style.MONOCHROME), input)
        for (filter in 1..4) {
            val filtered = render(parameters(ClassicNp3Style.MONOCHROME).copy(filterEffect = filter), input)
            assertTrue(!baseline.contentEquals(filtered))
            filtered.forEach { color ->
                assertEquals(color and 255, color ushr 8 and 255)
                assertEquals(color and 255, color ushr 16 and 255)
            }
        }
    }

    @Test fun monochromeToningIncludesAllColorsAndHonorsDensity() {
        val input = intArrayOf(0xff808080.toInt())
        val outputs = (1..9).map { tone ->
            render(parameters(ClassicNp3Style.MONOCHROME).copy(
                toningEffect = tone, toningDensityQuarter = 28,
            ), input).single()
        }
        assertEquals(9, outputs.toSet().size)
        outputs.forEach { assertNotEquals(input.single(), it) }
        val sepia = parameters(ClassicNp3Style.MONOCHROME).copy(toningEffect = 1)
        assertArrayEquals(input, render(sepia.copy(toningDensityQuarter = 0), input))
        assertNotEquals(render(sepia.copy(toningDensityQuarter = 16), input).single(),
            render(sepia.copy(toningDensityQuarter = 28), input).single())
    }

    @Test fun creativeFixedTonesHonorDensityWithoutASelectableToningEnum() {
        val input = intArrayOf(0xff808080.toInt(), 0xff467a96.toInt())
        for (base in listOf(ClassicNp3Style.RED, ClassicNp3Style.SEPIA, ClassicNp3Style.BLUE, ClassicNp3Style.PINK)) {
            val preset = parameters(base).copy(toningEffect = 0, toningDensityQuarter = 16)
            assertTrue(!render(preset, input).contentEquals(render(preset.copy(toningDensityQuarter = 28), input)))
            assertTrue(!render(preset.copy(effectLevel = 20), input)
                .contentEquals(render(preset.copy(effectLevel = 50), input)))
            assertArrayEquals(input, render(preset.copy(effectLevel = 0), input))
        }
    }

    @Test fun eachKnownBaseHasAnExplicitMappingAndSafeOutput() {
        val input = colors()
        for (base in ClassicNp3Style.entries) {
            assertEquals(base, ClassicNp3Style.fromNp3Id(base.id))
            val output = render(parameters(base), input)
            assertEquals(input.size, output.size)
            for (index in input.indices) assertEquals(input[index] ushr 24, output[index] ushr 24)
            if (base != ClassicNp3Style.STANDARD && base != ClassicNp3Style.AUTO) {
                assertTrue("${base.name} lost its base look", !input.contentEquals(output))
            }
            if (base.creative) assertArrayEquals(input, render(parameters(base).copy(effectLevel = 0), input))
        }
    }

    @Test fun previewAndMemoizedExportMatchAcrossBasesStrengthsAndAlphaModes() {
        val input = colors()
        for (base in ClassicNp3Style.entries) for (strength in listOf(2, 80, 100)) {
            val recipe = parameters(base).copy(contrastQuarter = -3, brightnessQuarter = 1,
                saturationQuarter = 2, hueQuarter = -1, toningDensityQuarter = 20)
            val selection = selection(recipe, strength)
            val opaque = compile.invoke(PhotoFilterRenderer, selection, false)
            val memo = ExactRgbMemo(bits = 4)
            for (alpha in listOf(false, true)) {
                val expected = render(recipe, input, strength, alpha)
                val actual = input.copyOf()
                memoized.invoke(PhotoFilterRenderer, actual, 0, actual.size, memo, opaque, alpha, notCancelled)
                assertArrayEquals("${base.name} strength=$strength alpha=$alpha", expected, actual)
            }
        }
    }

    private fun render(recipe: ClassicNp3PhotoFilterParameters, input: IntArray,
        strength: Int = 100, alpha: Boolean = true): IntArray = input.copyOf().also { output ->
        val compiled = compile.invoke(PhotoFilterRenderer, selection(recipe, strength), alpha)
        direct.invoke(PhotoFilterRenderer, output, 0, output.size, compiled, notCancelled)
    }

    private fun selection(parameters: ClassicNp3PhotoFilterParameters, strength: Int) =
        PhotoFilterSelection(PhotoFilterPreset("classic-test", "Classic", parameters), strength)

    private fun parameters(base: ClassicNp3Style = ClassicNp3Style.STANDARD) =
        ClassicNp3PhotoFilterParameters(base, 0, 0, 0, 0, 0, 0, 16, 100)

    private fun colors(): IntArray {
        val random = java.util.Random(34)
        return IntArray(512) { random.nextInt() } +
            intArrayOf(0, -1, 0x00123456, 0x7f123456, 0xff000000.toInt(), 0xff808080.toInt())
    }
}
