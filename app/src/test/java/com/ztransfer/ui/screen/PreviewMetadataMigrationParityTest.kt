package com.ztransfer.ui.screen

import java.util.Locale
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Test

/** Calls the production Android delegates against frozen pre-migration implementations. */
class PreviewMetadataMigrationParityTest {
    private fun <T> outcome(block: () -> T): Any? = try { block() } catch (e: Exception) { e.javaClass.name }

    @Test fun captureDateMatchesOriginalAcrossLocalesAndMalformedCameraValues() {
        val random = Random(4401)
        val samples = mutableListOf<String?>(null, "", "202609", "20260229", "00000229T235959", "19000229",
            "20000229T235960", "20260905t123456", "20260905T12", "20260905T123456.789+0800",
            "２０２６０９０５T１２３４５６", "٢٠٢٦٠٩٠٥T١٢٣٤٥٦", "20260905T999999", "20260905 123456")
        repeat(3000) {
            samples += String.format(Locale.ROOT, "%04d%02d%02dT%02d%02d%02d", random.nextInt(10000),
                random.nextInt(15), random.nextInt(35), random.nextInt(27), random.nextInt(65), random.nextInt(65))
        }
        val previous = Locale.getDefault()
        try {
            for (tag in listOf("en-US", "de-DE", "zh-CN", "ar-EG", "th-TH")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                for (raw in samples) assertEquals("$tag: $raw", outcome { originalPreviewCaptureDateText(raw) },
                    outcome { formatPreviewCaptureDate(raw) })
            }
        } finally { Locale.setDefault(previous) }
    }

    @Test fun videoMetadataKeepsUnknownSizeExactFourGiBBoundaryAndLocalizedDate() {
        val sizes = listOf(Long.MIN_VALUE, -1, 0, 1, 1023, 1024, 1025, 4294967294, 4294967295, 4294967296, 4294967297, Long.MAX_VALUE)
        val dates = listOf(null, "", "20260905", "00000229T000001", "20260230", "20260905T235959Z", "20260905T240000")
        val previous = Locale.getDefault()
        try {
            for (tag in listOf("en-US", "de-DE", "zh-CN", "ar-EG", "th-TH")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                for (size in sizes) for (date in dates) assertEquals("$tag/$size/$date",
                    originalPreviewVideoMetadataText(size, date, "超过4GB"), videoPreviewMetadata(size, date, "超过4GB"))
            }
        } finally { Locale.setDefault(previous) }
    }
}
