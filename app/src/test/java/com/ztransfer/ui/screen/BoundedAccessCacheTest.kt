package com.ztransfer.ui.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test

class BoundedAccessCacheTest {
    @Test
    fun reusesRecentValuesAndEvictsTheLeastRecentlyUsedEntry() {
        val closed = mutableListOf<String>()
        val cache = BoundedAccessCache(
            maxEntries = 3,
            createValue = { key: String -> CacheValue(key) },
            closeValue = { closed += it.key },
        )

        val firstA = cache.getOrCreate("A")
        cache.getOrCreate("B")
        cache.getOrCreate("C")
        assertSame(firstA, cache.getOrCreate("A"))

        cache.getOrCreate("D")
        assertEquals(listOf("B"), closed)
        assertNotSame(firstA, cache.getOrCreate("B"))
        assertEquals(listOf("B", "C"), closed)
    }

    @Test
    fun closeReleasesEveryRetainedValueExactlyOnce() {
        val closed = mutableListOf<String>()
        val cache = BoundedAccessCache(
            maxEntries = 3,
            createValue = { key: String -> CacheValue(key) },
            closeValue = { closed += it.key },
        )
        cache.getOrCreate("A")
        cache.getOrCreate("B")

        cache.close()
        cache.close()

        assertEquals(listOf("A", "B"), closed)
    }

    private data class CacheValue(val key: String)
}
