package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteProbeTest {
    @Test
    fun codeReportIsSortedDeduplicatedAndNeverTruncated() {
        val codes = (0x9400..0x9421).toList().reversed() + listOf(0x941E, 0x9400)

        val lines = formatProbeCodeLines(
            label = "operations",
            codes = codes,
            names = mapOf(0x941E to "PowerZoomByFocalLength"),
        )
        val report = lines.joinToString("\n")

        assertEquals(3, lines.size)
        assertTrue(lines.first().startsWith("operations (34) [1-16]: 0x9400"))
        assertTrue(report.contains("0x941E(PowerZoomByFocalLength)"))
        assertTrue(report.contains("0x9421"))
        assertEquals(1, Regex("0x941E").findAll(report).count())
    }

    @Test
    fun emptyCodeReportIsExplicit() {
        assertEquals(
            listOf("events (0): <none>"),
            formatProbeCodeLines("events", emptyList()),
        )
    }

    @Test
    fun rawPayloadHexKeepsUnsignedBytesAndEmptyStatesDistinct() {
        assertEquals("00FF1080", probeHex(byteArrayOf(0x00, 0xFF.toByte(), 0x10, 0x80.toByte())))
        assertEquals("<empty>", probeHex(byteArrayOf()))
        assertEquals("<none>", probeHex(null))
        assertFalse(probeHex(byteArrayOf(0xFF.toByte())).contains("FFFFFF"))
    }

    @Test
    fun digitalZoomCandidatesAreAlwaysPartOfKnownFallbackSurvey() {
        assertEquals(
            "NikonLiveViewImageZoomRatio",
            Lab.INTEREST_PROPS[Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO],
        )
        assertEquals(
            "DigitalZoom(std)",
            Lab.INTEREST_PROPS[Lab.PROP_DIGITAL_ZOOM],
        )
        assertEquals(
            setOf(Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO, Lab.PROP_DIGITAL_ZOOM),
            Lab.DIGITAL_ZOOM_PROPS.keys.toSet(),
        )
    }
}
