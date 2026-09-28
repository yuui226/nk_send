package com.ztransfer.lut

import org.junit.Assert.*
import org.junit.Test

class ParsedLutCacheTest {
    private fun table() = CubeLut(2, FloatArray(3), FloatArray(3), FloatArray(24), "test")

    @Test fun editsAndMissingMetadataInvalidateEntries() {
        val cache = ParsedLutCache()
        val lut = table()
        cache.put("a", 100, 1, lut)
        assertSame(lut, cache.get("a", 100, 1))
        assertNull(cache.get("a", 100, 2))
        assertNull(cache.get("a", 100, 1))
        cache.put("a", 100, 1, lut)
        assertNull(cache.get("a", null, 1))
        cache.put("a", 100, null, lut)
        assertNull(cache.get("a", 100, null))
    }

    @Test fun tinyTablesAlsoRespectEntryLimit() {
        val cache = ParsedLutCache(maxEntries = 2)
        cache.put("a", 100, 1, table())
        cache.put("b", 100, 1, table())
        cache.put("c", 100, 1, table())
        assertNull(cache.get("a", 100, 1))
        assertNotNull(cache.get("b", 100, 1))
        assertNotNull(cache.get("c", 100, 1))
    }

    @Test fun evictsLeastRecentlyUsedWithinByteBudget() {
        val cache = ParsedLutCache(192)
        val a = table(); val b = table(); val c = table()
        cache.put("a", 100, 1, a)
        cache.put("b", 100, 1, b)
        assertSame(a, cache.get("a", 100, 1))
        cache.put("c", 100, 1, c)
        assertNull(cache.get("b", 100, 1))
        assertSame(a, cache.get("a", 100, 1))
        assertSame(c, cache.get("c", 100, 1))
    }
}
