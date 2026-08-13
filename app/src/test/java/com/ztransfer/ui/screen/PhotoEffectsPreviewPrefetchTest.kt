package com.ztransfer.ui.screen

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoEffectsPreviewPrefetchTest {
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
