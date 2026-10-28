package com.ztransfer.ui.screen

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.LutAdjustments
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoEffectsPreviewPrefetchTest {
    @Test fun prefetchedFilterUsesItsOwnRememberedFinishingControls() {
        val controls = LutAdjustments(18, -26, 34, -42)
        val next = nextPhotoFilterSelections(
            filters = (1..3).map(::filter), favoriteCatalogKeys = emptyList(),
            rememberedIntensities = emptyMap(), selectedId = "filter-1", enabled = true,
            rememberedAdjustments = mapOf("filter-1" to LutAdjustments(-10), "filter-2" to controls),
        )
        assertEquals(listOf(controls, LutAdjustments()), next.map { it.lutAdjustments })
        assertEquals(controls, PhotoEffectsPreviewCacheKey.from(next.first()).let {
            LutAdjustments(it.contrast, it.saturation, it.highlights, it.shadows)
        })
    }

    @Test
    fun prefetchesOnlyTheNextTwoFiltersWithTheirRememberedIntensities() {
        val filters = (1..5).map(::filter)

        val next = nextPhotoFilterSelections(
            filters = filters,
            favoriteCatalogKeys = emptyList(),
            rememberedIntensities = mapOf("filter-4" to 64),
            selectedId = "filter-3",
            enabled = true,
        )

        assertEquals(listOf("filter-4", "filter-5"), next.map { it.preset.id })
        assertEquals(listOf(64, 80), next.map { it.normalizedIntensityPercent })
    }

    @Test
    fun disabledOrLastFilterDoesNotPrefetch() {
        val filters = (1..3).map(::filter)

        assertTrue(
            nextPhotoFilterSelections(
                filters,
                emptyList(),
                emptyMap(),
                selectedId = "filter-2",
                enabled = false,
            ).isEmpty(),
        )
        assertTrue(
            nextPhotoFilterSelections(
                filters,
                emptyList(),
                emptyMap(),
                selectedId = "filter-3",
                enabled = true,
            ).isEmpty(),
        )
    }

    @Test
    fun prefetchNeverRecyclesAResultThatDirectlyBecomesTheCachedPreview() {
        assertTrue(
            !shouldRecyclePrefetchInput(
                useCurrentFilteredSource = false,
                inputIsSource = false,
                outputIsInput = true,
            ),
        )
        assertTrue(
            shouldRecyclePrefetchInput(
                useCurrentFilteredSource = false,
                inputIsSource = false,
                outputIsInput = false,
            ),
        )
    }

    private fun filter(index: Int) = PhotoFilterPreset(
        id = "filter-$index",
        name = "Filter $index",
        parameters = NcpPhotoFilterParameters(
            saturationStep = 0,
            hueStep = 0,
            toneCurve = IntArray(257) { point -> point * 0x7fff / 256 },
        ),
    )
}
