package com.ztransfer.preview

import kotlin.test.*

class PreviewExifPolicyTest {
    private val calls = mutableListOf<Triple<Float, Int, Boolean>>()
    private val formatter = PreviewExifDecimalFormatter { value, digits, root ->
        calls += Triple(value, digits, root); "$value:$digits:$root"
    }
    private fun values(vararg fields: Pair<PreviewExifTag, String?>) = NativePreviewExifValues().apply {
        fields.forEach { (tag, value) -> set(tag, value) }
    }

    @Test fun rationalKeepsFloatDivisionAndExistingNonfiniteInputs() {
        assertEquals(2.8f, parsePreviewExifRational("28/10"))
        assertEquals(1f / 250f, parsePreviewExifRational("1/250"))
        assertNull(parsePreviewExifRational("1/0")); assertNull(parsePreviewExifRational("/2"))
        assertNull(parsePreviewExifRational("1/2/3")); assertNull(parsePreviewExifRational(null))
        assertTrue(assertNotNull(parsePreviewExifRational("NaN")).isNaN())
        assertEquals(Float.POSITIVE_INFINITY, parsePreviewExifRational("Infinity"))
    }

    @Test fun fNumberAndDateUseLazyFallbacksExactlyOnce() {
        val read = mutableListOf<PreviewExifTag>()
        val source = object : PreviewExifSource {
            override fun attribute(tag: PreviewExifTag): String? {
                read += tag
                check(tag !in listOf(PreviewExifTag.APERTURE_VALUE, PreviewExifTag.DATETIME_DIGITIZED, PreviewExifTag.DATETIME))
                return when (tag) { PreviewExifTag.F_NUMBER -> "4"; PreviewExifTag.DATETIME_ORIGINAL -> "original"; else -> null }
            }
            override fun decodedCoordinates() = doubleArrayOf(31.2, 121.5)
            override fun decodedAltitude() = 0.0
        }
        val result = assertNotNull(parsePreviewExif(source, formatter))
        assertEquals("original", result.dateTime); assertEquals("f/4.0:0:false", result.aperture)
        assertFalse(PreviewExifTag.GPS_LATITUDE in read); assertEquals(read.size, read.distinct().size)
    }

    @Test fun apertureApexAndShutterBranchesKeepFloatAndNoExtraFallback() {
        val result = assertNotNull(parsePreviewExif(values(PreviewExifTag.APERTURE_VALUE to "4", PreviewExifTag.EXPOSURE_TIME to "3/2"), formatter))
        assertEquals("f/4.0:0:false", result.aperture); assertEquals("1.5:1:falses", result.shutterSpeed)
        calls.clear()
        parsePreviewExif(values(PreviewExifTag.F_NUMBER to "2.01", PreviewExifTag.EXPOSURE_TIME to "1/250", PreviewExifTag.FOCAL_LENGTH to "85"), formatter)
        assertEquals(listOf(0, 0, 0), calls.map { it.second })
        assertTrue(calls.all { !it.third })
    }

    @Test fun rawIsoAndDateWhitespaceAreNotNormalizedLikePhotoFrames() {
        val result = assertNotNull(parsePreviewExif(values(
            PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY to "", PreviewExifTag.LENS_MODEL to "  NIKKOR  ",
            PreviewExifTag.DATETIME_ORIGINAL to " ", PreviewExifTag.DATETIME_DIGITIZED to " 2026:09:05 01:02:03 ",
        ), formatter))
        assertEquals("ISO", result.iso); assertEquals("NIKKOR", result.lensModel)
        assertEquals(" 2026:09:05 01:02:03 ", result.dateTime)
    }

    @Test fun onlyNonzeroFiniteExposureCompensationUsesRootLocale() {
        for (value in listOf(null, "0", "-0.01", "NaN", "Infinity")) {
            val result = assertNotNull(parsePreviewExif(values(PreviewExifTag.EXPOSURE_BIAS_VALUE to value), formatter))
            assertNull(result.exposureCompensation)
        }
        assertTrue(calls.isEmpty())
        val result = assertNotNull(parsePreviewExif(values(PreviewExifTag.EXPOSURE_BIAS_VALUE to "2/3"), formatter))
        assertTrue(assertNotNull(result.exposureCompensation).startsWith("+"))
        assertEquals(Triple(2f / 3f, 1, true), calls.single())
    }

    @Test fun gpsFallbackPreservesDmsReferencesPairRequirementAndZeroPolicy() {
        val source = values(PreviewExifTag.GPS_LATITUDE to "[31/1, 12/1, 30/1]", PreviewExifTag.GPS_LATITUDE_REF to "s",
            PreviewExifTag.GPS_LONGITUDE to "121.5", PreviewExifTag.GPS_LONGITUDE_REF to "W")
        source.setDecodedCoordinates(Double.NaN, 0.0)
        val result = assertNotNull(parsePreviewExif(source, formatter))
        assertEquals(-(31.0 + 12.0 / 60 + 30.0 / 3600), result.latitude)
        assertEquals(-121.5, result.longitude)
        source.set(PreviewExifTag.GPS_LATITUDE, "91")
        val invalid = assertNotNull(parsePreviewExif(source, formatter))
        assertNull(invalid.latitude); assertNull(invalid.longitude)
        source.set(PreviewExifTag.GPS_LATITUDE, "0"); source.set(PreviewExifTag.GPS_LONGITUDE, "0")
        val zero = assertNotNull(parsePreviewExif(source, formatter))
        assertEquals(-0.0, zero.latitude); assertEquals(-0.0, zero.longitude)
    }

    @Test fun altitudeRemainsIndependentAndOnlyFiniteNonzero() {
        val source = values()
        for (altitude in listOf(Double.NaN, Double.POSITIVE_INFINITY, 0.0, -0.0)) {
            source.altitudeMeters = altitude
            assertNull(assertNotNull(parsePreviewExif(source, formatter)).altitudeMeters)
        }
        source.altitudeMeters = -15.5
        assertEquals(-15.5, assertNotNull(parsePreviewExif(source, formatter)).altitudeMeters)
    }

    @Test fun zeroAndNanExposureKeepOriginalVisibleFormattingQuirks() {
        parsePreviewExif(values(PreviewExifTag.EXPOSURE_TIME to "0"), formatter)
        assertEquals(Float.POSITIVE_INFINITY, calls.single().first)
        calls.clear(); parsePreviewExif(values(PreviewExifTag.EXPOSURE_TIME to "NaN"), formatter)
        assertTrue(calls.single().first.isNaN())
    }

    @Test fun nativeValuesOwnTheirCoordinateArrayAndUseSameParser() {
        val source = values(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY to "64")
        source.setDecodedCoordinates(1.25, 2.5)
        source.decodedCoordinates()!![0] = 80.0
        val result = assertNotNull(NativePreviewExifBridge.metadata(source, formatter))
        assertEquals(1.25, result.latitude); assertEquals("ISO64", result.iso)
        source.set(PreviewExifTag.PHOTOGRAPHIC_SENSITIVITY, null)
        assertNull(assertNotNull(NativePreviewExifBridge.metadata(source, formatter)).iso)
    }
}
