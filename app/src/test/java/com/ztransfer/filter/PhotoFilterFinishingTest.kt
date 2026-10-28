package com.ztransfer.filter

import com.ztransfer.lut.CubeLutParser
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the production preview/export pixel loops without allocating Android bitmaps. */
class PhotoFilterFinishingTest {
    private val methods = PhotoFilterRenderer.javaClass.declaredMethods
    private val compile = methods.single { it.name == "compileFilter" }.apply { isAccessible = true }
    private val direct = methods.single { it.name == "filterPixelRange" }.apply { isAccessible = true }
    private val memoized = methods.single { it.name == "applyExactRgbMemoRange" }.apply { isAccessible = true }
    private val notCancelled = { false }
    private val adjustments = listOf(
        LutAdjustments(contrast = 37),
        LutAdjustments(saturation = -42),
        LutAdjustments(highlights = -31),
        LutAdjustments(shadows = -28),
        LutAdjustments(contrast = 17, saturation = 24, highlights = -29, shadows = -18),
    )

    @Test fun eachFinishingControlAppliesOnceAfterIntensityForAllBuiltInsAndNp3Families() {
        val input = colors()
        for (preset in presets()) for (strength in listOf(2, 80, 100)) {
            for (preserveAlpha in listOf(false, true)) {
                val baseline = PhotoFilterSelection(preset, strength)
                val filtered = render(baseline, input, preserveAlpha)
                assertArrayEquals(filtered, render(baseline.copy(lutAdjustments = LutAdjustments()),
                    input, preserveAlpha))
                for (finish in adjustments) {
                    val expected = filtered.map {
                        LutColorPipeline.apply(it, finish, preserveAlpha)
                    }.toIntArray()
                    assertArrayEquals("${preset.name} strength=$strength alpha=$preserveAlpha $finish",
                        expected, render(baseline.copy(lutAdjustments = finish), input, preserveAlpha))
                }
            }
        }
    }

    @Test fun weakFilterIntensityDoesNotWeakenFinishingControls() {
        val preset = classic(ClassicNp3Style.STANDARD)
        val input = colors()
        for (finish in adjustments) {
            val expected = input.map { LutColorPipeline.apply(it, finish, true) }.toIntArray()
            assertTrue("Fixture must exercise a visible adjustment", !input.contentEquals(expected))
            for (strength in listOf(2, 40, 100)) {
                assertArrayEquals(expected, render(PhotoFilterSelection(preset, strength, finish), input, true))
            }
        }
    }

    @Test fun adjustedPreviewAndMemoizedExportMatchIncludingWarmHitsAndAlpha() {
        val input = colors()
        for (preset in presets()) for (strength in listOf(2, 80, 100)) {
            val selection = PhotoFilterSelection(preset, strength, adjustments.last())
            val compiled = compile.invoke(PhotoFilterRenderer, selection, false)
            val memo = ExactRgbMemo(bits = 6)
            for (preserveAlpha in listOf(false, true)) {
                val expected = render(selection, input, preserveAlpha)
                repeat(2) {
                    val actual = input.copyOf()
                    memoized.invoke(PhotoFilterRenderer, actual, 0, actual.size, memo, compiled,
                        preserveAlpha, notCancelled)
                    assertArrayEquals("${preset.name} strength=$strength alpha=$preserveAlpha",
                        expected, actual)
                }
            }
        }
    }

    @Test fun originalExportCacheCannotReusePixelsFromDifferentFinishingSettings() {
        val base = PhotoFilterSelection(BuiltInPhotoFilters.all.first(), 80)
        val input = colors()
        val original = PhotoFilterRenderer.prepareOriginalFilter(base)
        val originalPixels = renderPrepared(original, input)
        val changedSelection = base.copy(lutAdjustments = adjustments.last())
        val changed = PhotoFilterRenderer.prepareOriginalFilter(changedSelection)
        assertNotSame(original.exactRgbMemo, changed.exactRgbMemo)
        val changedPixels = renderPrepared(changed, input)
        assertArrayEquals(render(changedSelection, input, true), changedPixels)
        assertTrue(!originalPixels.contentEquals(changedPixels))

        // Intensity detents normalize before cache lookup, just as before finishing was added.
        val same = PhotoFilterRenderer.prepareOriginalFilter(changedSelection.copy(intensityPercent = 79))
        assertSame(changed.exactRgbMemo, same.exactRgbMemo)
        assertArrayEquals(changedPixels, renderPrepared(same, input))
        assertArrayEquals(originalPixels, renderPrepared(PhotoFilterRenderer.prepareOriginalFilter(base), input))
    }

    @Test fun lutStillUsesItsOriginalMapperAndTheSameFinishingOrder() {
        val table = CubeLutParser.parse(("LUT_3D_SIZE 2\n" +
            "0 0 0\n0 0 1\n0 1 0\n0 1 1\n" +
            "1 0 0\n1 0 1\n1 1 0\n1 1 1\n").byteInputStream())
        val parameters = CubePhotoFilterParameters(table)
        val preset = PhotoFilterPreset("cube:finishing-fixture", "LUT", parameters)
        val input = colors()
        for (strength in listOf(2, 80, 100)) for (preserveAlpha in listOf(false, true)) {
            for (finish in adjustments + LutAdjustments()) {
                val expected = input.map {
                    LutColorPipeline.apply(parameters.mapper.map(it, strength / 100f, preserveAlpha),
                        finish, preserveAlpha)
                }.toIntArray()
                assertArrayEquals(expected, render(PhotoFilterSelection(preset, strength, finish),
                    input, preserveAlpha))
            }
        }
    }

    private fun render(selection: PhotoFilterSelection, input: IntArray, preserveAlpha: Boolean): IntArray =
        input.copyOf().also { output ->
            val compiled = compile.invoke(PhotoFilterRenderer, selection, preserveAlpha)
            direct.invoke(PhotoFilterRenderer, output, 0, output.size, compiled, notCancelled)
        }

    private fun renderPrepared(prepared: PhotoFilterRenderer.PreparedOriginalFilter, input: IntArray): IntArray =
        input.copyOf().also { output ->
            val memo = checkNotNull(prepared.exactRgbMemo)
            val compiled = compile.invoke(PhotoFilterRenderer, prepared.selection, false)
            memoized.invoke(PhotoFilterRenderer, output, 0, output.size, memo, compiled, true, notCancelled)
        }

    private fun presets(): List<PhotoFilterPreset> = BuiltInPhotoFilters.all + listOf(
        PhotoFilterPreset("graded-np3", "Graded NP3", Np3PhotoFilterParameters(
            13, -20, 25, 0, -5, 20,
            PHOTO_FILTER_COLOR_BAND_CENTERS.map { PhotoFilterColorBand(it, 10, -15, 5) },
            colorGrading = Np3ColorGrading(
                highlights = Np3ColorGradingRegion(40, 35, 15),
                midtones = Np3ColorGradingRegion(140, 25, -20),
                shadows = Np3ColorGradingRegion(220, 45, 10), blending = 70, balance = -20,
            ),
        )),
        classic(ClassicNp3Style.VIVID),
        classic(ClassicNp3Style.MONOCHROME),
        classic(ClassicNp3Style.PORTRAIT).let { preset ->
            preset.copy(parameters = (preset.parameters as ClassicNp3PhotoFilterParameters).copy(
                toneCurve = IntArray(257) { 1024 + it * 118 },
            ))
        },
        PhotoFilterPreset("legacy-ncp", "NCP", NcpPhotoFilterParameters(
            saturationStep = 1, hueStep = -1,
            toneCurve = IntArray(257) { it * 0x7fff / 256 },
        )),
    )

    private fun classic(style: ClassicNp3Style) = PhotoFilterPreset(
        "classic-finishing-${style.name}", "Classic ${style.name}",
        ClassicNp3PhotoFilterParameters(style, 0, 0, 0, 0, 0, 0, 16, 100),
    )

    private fun colors(): IntArray {
        val random = java.util.Random(48)
        return IntArray(128) { random.nextInt() } + intArrayOf(
            0, 0x00123456, 0x7f123456, 0xff000000.toInt(), 0xff202020.toInt(),
            0xff808080.toInt(), 0xffeeeeee.toInt(), -1,
        )
    }
}
