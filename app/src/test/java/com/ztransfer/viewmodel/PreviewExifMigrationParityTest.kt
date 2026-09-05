package com.ztransfer.viewmodel

import com.ztransfer.preview.*
import com.ztransfer.previewbaseline.parseExifImpl as baseline
import java.util.Locale
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Test

class PreviewExifMigrationParityTest {
    private class Source(val values: Map<PreviewExifTag, String?>, val gps: DoubleArray?, val altitude: Double) : PreviewExifSource {
        val reads = mutableListOf<String>()
        override fun attribute(tag: PreviewExifTag): String? { reads += tag.name; return values[tag] }
        override fun decodedCoordinates(): DoubleArray? { reads += "coordinates"; return gps }
        override fun decodedAltitude(): Double { reads += "altitude"; return altitude }
    }
    private fun check(values: Map<PreviewExifTag, String?>, gps: DoubleArray? = null, altitude: Double = Double.NaN) {
        val original = Source(values, gps, altitude); val shared = Source(values, gps, altitude)
        assertEquals(baseline(original), parsePreviewExif(shared, AndroidPreviewExifDecimalFormatter))
        assertEquals(original.reads, shared.reads)
    }

    @Test fun randomizedValuesAndTagAccessOrderMatchOriginalAcrossLocales() {
        val previous = Locale.getDefault()
        val random = Random(55876)
        val pool = listOf(null, "", " ", "2.8", "4", "1/250", "1/0", "NaN", "Infinity", "-0.0", "1e38", "0x1.0p2", "64", "2/3", "-4/3", "[31,12,30]", "W", "2026:09:05 01:02:03")
        try {
            for (locale in listOf(Locale.US, Locale.FRANCE, Locale.forLanguageTag("ar-EG"), Locale.CHINA, Locale.ROOT)) {
                Locale.setDefault(locale)
                repeat(800) {
                    val values = PreviewExifTag.entries.associateWith { pool[random.nextInt(pool.size)] }
                    val gps = when (it % 4) { 0 -> doubleArrayOf(31.123456789, 121.987654321); 1 -> doubleArrayOf(0.0, Double.NaN); 2 -> doubleArrayOf(-91.0); else -> null }
                    check(values, gps, listOf(0.0, -15.25, Double.NaN, Double.POSITIVE_INFINITY)[it % 4])
                }
            }
        } finally { Locale.setDefault(previous) }
    }

    @Test fun apexCommonPowAndFloatFormattingMatchAndroidMathPow() {
        val random = Random(34)
        repeat(4000) {
            val apex = Float.fromBits(random.nextInt())
            check(mapOf(PreviewExifTag.APERTURE_VALUE to apex.toString()))
        }
    }

    @Test fun frenchPreviewUsesLocaleButExposureCompensationStaysRoot() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.FRANCE)
            val values = NativePreviewExifValues().apply {
                set(PreviewExifTag.F_NUMBER, "28/10"); set(PreviewExifTag.EXPOSURE_TIME, "3/2")
                set(PreviewExifTag.EXPOSURE_BIAS_VALUE, "2/3")
            }
            val result = parsePreviewExif(values, AndroidPreviewExifDecimalFormatter)!!
            assertEquals("f/2,8", result.aperture); assertEquals("1,5s", result.shutterSpeed)
            assertEquals("+0.7 EV", result.exposureCompensation)
        } finally { Locale.setDefault(previous) }
    }

    @Test fun unusualRationalAndGpsInputsAreNotSilentlyCleanedUp() {
        for (rational in listOf("-1", "0", "-0.0", "1/0", "NaN", "Infinity", "1e-44", "2.05", "3/2/1")) {
            check(mapOf(PreviewExifTag.F_NUMBER to rational, PreviewExifTag.EXPOSURE_TIME to rational,
                PreviewExifTag.GPS_LATITUDE to "[\"31/1\"; '12/1'; 30/1]", PreviewExifTag.GPS_LATITUDE_REF to "S",
                PreviewExifTag.GPS_LONGITUDE to "121.55555555", PreviewExifTag.GPS_LONGITUDE_REF to "W"))
        }
    }
}
