package com.ztransfer.filter

import org.junit.Assert.*
import org.junit.Test

class PhotoFilterIdentityTest {
    @Test fun builtInIdentityRemainsTheOriginalSourceHash() {
        BuiltInPhotoFilters.all.forEach { preset ->
            assertEquals(BuiltInPhotoFilters.catalogKey(preset.id), photoFilterCatalogKey(preset.id))
            assertFalse(isCustomPhotoFilterCatalogKey(requireNotNull(photoFilterCatalogKey(preset.id))))
        }
    }

    @Test fun customRenderIdentityUsesAStableNamespacedPreferenceKey() {
        val source = "abc123".repeat(10) + "abcd"
        val key = photoFilterCatalogKey("np3:$source:np3-srgb-v1")
        assertEquals("np3:$source", key)
        assertTrue(isCustomPhotoFilterCatalogKey(requireNotNull(key)))
        assertNotEquals(source, key)
    }

    @Test fun unknownIdsAndMalformedCustomKeysAreNeverTrusted() {
        val source = "a".repeat(64)
        for (id in listOf(source, "missing", "np3:$source", "np3:$source:np3-srgb-v2",
            "np3:${source.uppercase()}:np3-srgb-v1", "np3:$source:np3-srgb-v1:extra",
            "np3:${source.dropLast(1)}:np3-srgb-v1", "np3:$source:np3-srgb-v1\n")) {
            assertNull(id, photoFilterCatalogKey(id))
        }
        for (key in listOf(source, "np3:missing", "np3:$source:np3-srgb-v1", "np3:$source\n",
            "np3:${source.uppercase()}", "np3:${source}a")) {
            assertFalse(key, isCustomPhotoFilterCatalogKey(key))
        }
    }
}
