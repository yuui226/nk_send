package com.ztransfer.ui

import kotlin.test.*

class NativeBrowsePreferencesTest {
    @Test fun actualRestoredDefaultsAndColumnLimitsUseOriginalPolicy() {
        val defaults = NativeBrowsePreferences.defaults()
        assertEquals(3, defaults.columns)
        assertTrue(defaults.collapseBursts)
        assertNull(defaults.extensions)
        assertFalse(defaults.protectedOnly || defaults.burstOnly || defaults.untransferredOnly)
        for ((input, expected) in listOf(-1 to 2, 1 to 2, 2 to 2, 3 to 3, 4 to 4, 100 to 4)) {
            assertEquals(expected, NativeBrowsePreferences(input, false, null, false, false, false, 0, 0).columns)
        }
    }

    @Test fun dateRestoreUsesSharedValidationAndReordersEndpoints() {
        val reversed = NativeBrowsePreferences(3, true, null, false, false, false, 20260905, 20260228)
        assertEquals(20260228, reversed.startDay); assertEquals(20260905, reversed.endDay)
        for ((first, last) in listOf(0 to 20260905, 20260905 to 0, 20260229 to 20260905, -1 to 0)) {
            val invalid = NativeBrowsePreferences(3, true, null, false, false, false, first, last)
            assertEquals(0, invalid.startDay); assertEquals(0, invalid.endDay)
            assertNull(invalid.criteria().dateRange)
        }
    }

    @Test fun inputCollectionsAreCopiedAndNullDiffersFromExplicitEmpty() {
        val source = mutableListOf(".JPG", ".NEF", ".JPG")
        val prefs = NativeBrowsePreferences(3, false, source, true, true, true, 0, 0)
        source.clear()
        assertEquals(listOf(".JPG", ".NEF"), prefs.extensions)
        assertEquals(setOf(".JPG", ".NEF"), prefs.criteria().extensions)
        assertNull(prefs.criteria().storageSlot)
        assertEquals(emptySet(), NativeBrowsePreferences(3, true, emptyList(), false, false, false, 0, 0).criteria().extensions)
        assertNull(NativeBrowsePreferences.defaults().criteria().extensions)
    }
}
