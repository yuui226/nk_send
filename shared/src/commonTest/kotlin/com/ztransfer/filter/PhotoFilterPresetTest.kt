package com.ztransfer.filter

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class PhotoFilterPresetTest {
    @Test
    fun colorBandCentersRemainPrimitiveHotPathLookup() {
        assertContentEquals(
            floatArrayOf(0f, 30f, 60f, 120f, 180f, 240f, 280f, 320f),
            PHOTO_FILTER_COLOR_BAND_CENTERS,
        )
    }

    @Test
    fun toneCurveMapsEndpointsAndInterpolatesBetweenSamples() {
        val curve = FloatArray(PHOTO_FILTER_TONE_CURVE_POINT_COUNT) { index ->
            index.toFloat() / (PHOTO_FILTER_TONE_CURVE_POINT_COUNT - 1)
        }

        assertEquals(0f, mapPhotoFilterToneCurve(-1f, curve), 0f)
        assertEquals(0.5f, mapPhotoFilterToneCurve(0.5f, curve), 0.0001f)
        assertEquals(1f, mapPhotoFilterToneCurve(2f, curve), 0f)
    }

    @Test
    fun intensityUsesTwoPercentDetentsAndNeverRepresentsFilterOff() {
        assertEquals(2, normalizePhotoFilterIntensity(-1))
        assertEquals(2, normalizePhotoFilterIntensity(0))
        assertEquals(72, normalizePhotoFilterIntensity(72))
        assertEquals(74, normalizePhotoFilterIntensity(73))
        assertEquals(100, normalizePhotoFilterIntensity(101))
    }
}
