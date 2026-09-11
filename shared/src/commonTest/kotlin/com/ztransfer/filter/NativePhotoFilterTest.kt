package com.ztransfer.filter

import kotlin.test.*

class NativePhotoFilterTest {
    @Test fun everyBuiltInUsesExistingKernelForRgbAndAlpha() {
        val source = intArrayOf(0, 0x00112233, 0x80406080.toInt(), 0xff204080.toInt(), -1, 0xff000000.toInt())
        for (preset in BuiltInPhotoFilters.all) for (alpha in listOf(true, false)) for (strength in listOf(2, 80, 100)) {
            val selection = PhotoFilterSelection(preset, strength)
            val pixels = source.copyOf()
            assertTrue(NativePhotoFilter(selection, alpha).render(pixels, pixels.size))
            assertContentEquals(renderPhotoFilterArgbPixels(source, selection, alpha), pixels)
        }
    }
    @Test fun invalidRangeDoesNotTouchInputAndShortChunkLeavesTail() {
        val selection = PhotoFilterSelection(BuiltInPhotoFilters.all.first(), 80)
        val renderer = NativePhotoFilter(selection, true)
        val pixels = IntArray(4097) { -1 }
        assertFalse(renderer.render(pixels, -1))
        assertFalse(renderer.render(pixels, 4097))
        assertContentEquals(IntArray(4097) { -1 }, pixels)
        assertTrue(renderer.render(pixels, 0))
        assertTrue(renderer.render(pixels, 1))
        assertEquals(-1, pixels[1])
    }
    @Test fun catalogPreservesExistingOrderAndIntensityNormalization() {
        assertEquals(BuiltInPhotoFilters.all.size, NativePhotoFilterCatalog.count())
        for (index in BuiltInPhotoFilters.all.indices) {
            val selection = assertNotNull(NativePhotoFilterCatalog.selection(index, 0))
            assertEquals(BuiltInPhotoFilters.all[index], selection.preset)
            assertEquals(PhotoFilterSelection(selection.preset, 0).normalizedIntensityPercent, selection.normalizedIntensityPercent)
        }
        assertNull(NativePhotoFilterCatalog.selection(-1, 80))
        assertNull(NativePhotoFilterCatalog.selection(BuiltInPhotoFilters.all.size, 80))
    }

    @Test fun catalogExposesStableScalarMetadataForNativeClients() {
        val count = NativePhotoFilterCatalog.count()
        assertTrue(count > 0)
        for (index in 0 until count) {
            assertTrue(assertNotNull(NativePhotoFilterCatalog.id(index)).isNotBlank())
            assertTrue(assertNotNull(NativePhotoFilterCatalog.name(index)).isNotBlank())
            assertTrue(assertNotNull(NativePhotoFilterCatalog.categoryTitle(index)).isNotBlank())
            assertTrue(assertNotNull(NativePhotoFilterCatalog.catalogKey(index)).isNotBlank())
        }
        assertNull(NativePhotoFilterCatalog.id(-1))
        assertNull(NativePhotoFilterCatalog.categoryTitle(count))
    }
}
