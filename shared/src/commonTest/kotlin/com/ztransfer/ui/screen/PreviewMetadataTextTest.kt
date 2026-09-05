package com.ztransfer.ui.screen

import kotlin.test.*

class PreviewMetadataTextTest {
    private val events = mutableListOf<String>()
    private fun date(raw: String?): String? = previewCaptureDateText(raw,
        { y, m, d -> events += "date"; "$y/$m/$d" },
        { h, m, s -> events += "time"; "$h:$m:$s" })

    @Test fun invalidDatesNeverCallPlatformFormatter() {
        for (raw in listOf(null, "", "2026", "20260229", "19000229", "20260001", "20261301", "20260100", "20260431")) {
            assertNull(date(raw), raw); assertTrue(events.isEmpty(), raw)
        }
    }
    @Test fun prolepticYearZeroAndGregorianLeapCycleRemainAccepted() {
        assertEquals("0/2/29 0:0:1", date("00000229T000001"))
        assertEquals(listOf("date", "time"), events)
        assertEquals("2000/2/29", date("20000229"))
        assertNull(date("21000229"))
    }
    @Test fun invalidOrPartialTimeFallsBackToDateWithoutTimeFormatter() {
        for (suffix in listOf("", "T12", "t123456", "T240000", "T126000", "T123460", "Tabcdef", " 123456")) {
            events.clear(); assertEquals("2026/9/5", date("20260905$suffix"))
            assertEquals(listOf("date"), events)
        }
        assertEquals("2026/9/5 12:34:56", date("20260905T123456.123+0800"))
    }
    @Test fun unknownOrOverLimitSkipsSizeFormatterButAlwaysChecksCaptureDate() {
        for (size in listOf(-1L, 0L, 4294967295L, 4294967297L)) {
            events.clear()
            val output = previewVideoMetadataText(size, null, "large", { events += "size"; "$it" }, { events += "date"; null })
            assertEquals(if (size > 0) "large" else "", output)
            assertEquals(listOf("date"), events)
        }
    }
    @Test fun exactFourGiBIsFormattedNormallyAndOriginalSeparatorRemains() {
        val value = previewVideoMetadataText(4294967296L, "x", "large",
            { events += "size:$it"; "4.0 GB" }, { events += "date:$it"; "2026-09-05" })
        assertEquals("4.0 GB  ·  2026-09-05", value)
        assertEquals(listOf("size:4294967296", "date:x"), events)
    }
}
