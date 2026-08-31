package com.ztransfer.gps

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GpsPlaceLookupTest {
    @Test
    fun nearbyCoordinatesReuseTheSameCachedPlace() {
        val cache = GpsPlaceNameCache()

        cache.put(31.23041, 121.47371, "测试地点")

        assertEquals("测试地点", cache.get(31.23044, 121.47374))
        assertNull(cache.get(31.23200, 121.47600))
    }

    @Test
    fun cacheKeepsOnlyTheMostRecentlyUsedCells() {
        val cache = GpsPlaceNameCache(maxEntries = 2)
        cache.put(10.0, 10.0, "A")
        cache.put(20.0, 20.0, "B")
        assertEquals("A", cache.get(10.0, 10.0))

        cache.put(30.0, 30.0, "C")

        assertEquals("A", cache.get(10.0, 10.0))
        assertNull(cache.get(20.0, 20.0))
        assertEquals("C", cache.get(30.0, 30.0))
    }

    @Test
    fun cacheKeyAlwaysUsesProtocolSafeDecimalPoints() {
        val originalLocale = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("31.230,121.474", gpsPlaceCacheKey(31.2304, 121.4737))
        } finally {
            Locale.setDefault(originalLocale)
        }
    }

    @Test
    fun cachedNamesDoNotLeakAcrossLanguages() {
        val cache = GpsPlaceNameCache()
        cache.put(31.2304, 121.4737, "上海", Locale.SIMPLIFIED_CHINESE)

        assertEquals(
            "上海",
            cache.get(31.2304, 121.4737, Locale.SIMPLIFIED_CHINESE),
        )
        assertNull(cache.get(31.2304, 121.4737, Locale.ENGLISH))
    }
}
