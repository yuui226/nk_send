package com.ztransfer.filter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFilterPresetTest {
    @Test
    fun colorBandInterpolationWrapsSmoothlyAcrossRed() {
        val centers = PHOTO_FILTER_COLOR_BAND_CENTERS.toList()
        val nearEnd = adjacentColorBandWeights(350f, centers)
        val nearStart = adjacentColorBandWeights(10f, centers)

        assertEquals(7, nearEnd.first)
        assertEquals(0, nearEnd.second)
        assertEquals(0, nearStart.first)
        assertEquals(1, nearStart.second)
        assertTrue(nearEnd.third in 0f..1f)
        assertTrue(nearStart.third in 0f..1f)
    }

    @Test
    fun intensityIsAlwaysSafeForRendering() {
        assertEquals(0, normalizePhotoFilterIntensity(-1))
        assertEquals(72, normalizePhotoFilterIntensity(72))
        assertEquals(100, normalizePhotoFilterIntensity(101))
    }
}
