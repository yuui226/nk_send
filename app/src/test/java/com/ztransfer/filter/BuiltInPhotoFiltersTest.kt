package com.ztransfer.filter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BuiltInPhotoFiltersTest {
    @Test
    fun starterSetIsSmallStableAndFullyRenderable() {
        val filters = BuiltInPhotoFilters.all

        assertEquals(5, filters.size)
        assertEquals(filters.size, filters.map { it.id }.distinct().size)
        filters.forEach { filter ->
            assertTrue(filter.id.matches(Regex("[0-9a-f]{64}")))
            assertEquals(8, filter.colorBands.size)
            assertTrue(filter.contrast in -100..100)
            assertTrue(filter.highlights in -100..100)
            assertTrue(filter.shadows in -100..100)
            assertTrue(filter.whiteLevel in -100..100)
            assertTrue(filter.blackLevel in -100..100)
            assertTrue(filter.saturation in -100..100)
            filter.colorBands.forEach { band ->
                assertTrue(band.hue in -100..100)
                assertTrue(band.chroma in -100..100)
                assertTrue(band.brightness in -100..100)
            }
            assertTrue(BuiltInPhotoFilters.nameResId(filter.id) != null)
        }
    }

    @Test
    fun documentaryPresetIsActuallyMonochrome() {
        val mono = BuiltInPhotoFilters.all.single { it.name == "Documentary Mono" }

        assertEquals(-100, mono.saturation)
    }

    @Test
    fun unknownImportedPresetHasNoBuiltInLabel() {
        assertEquals(null, BuiltInPhotoFilters.nameResId("f".repeat(64)))
    }
}
