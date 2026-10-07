package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class LiveViewFocusDiagnosticTest {
    private fun packet(time: Long) = LiveViewPacket(ByteArray(515), 512, null, time, 0x9428)

    @Test fun passiveCaptureIsBoundedAndRestartClearsPreviousReport() {
        val log = LiveViewFocusDiagnostic()
        log.sample(packet(0), "ignored")
        assertEquals("", log.report())
        log.start(0, "Z30")
        for (i in 0..600) {
            log.sample(packet(i * 100L), "photo")
            if (i == 10) log.mark(1000, "first-step")
        }
        assertTrue(log.report().contains("changes=1"))
        assertFalse(log.running)
        assertTrue(log.report().length <= 6000)
        assertTrue(log.report().contains("first-step"))
        assertTrue(log.report().startsWith("Focus diagnostic v2 Z30"))
        assertTrue(log.report().contains("end=60s samples=300"))
        log.start(70_000, "new-camera")
        assertFalse(log.report().contains("Z30"))
        log.stop()
        val frozen = log.report()
        log.sample(packet(71_000), "ignored")
        assertEquals(frozen, log.report())
    }

    @Test fun malformedShortPacketsRemainDiagnosableWithoutBoundsExceptions() {
        val log = LiveViewFocusDiagnostic()
        log.start(0, "test")
        log.sample(LiveViewPacket(byteArrayOf(1), 0, null, 1, 0x9203), "movie")
        assertTrue(log.report().contains("unsupported-header"))
        assertTrue(log.report().contains("op=9203"))
    }
    @Test fun selectedRawRecordSurvivesLongReportsAndLargeIndexes() {
        val log = LiveViewFocusDiagnostic()
        log.start(0, "camera".repeat(300))
        val bytes = ByteArray(515)
        bytes[44] = 6
        bytes[45] = 5
        bytes[89] = 30 // selected record at 48 + 5 * 8
        bytes[91] = 20
        bytes[93] = 100
        bytes[95] = 80
        for (i in 0..299) {
            log.sample(LiveViewPacket(bytes, 512, null, i * 200L, 0x9428), "mode".repeat(100))
            if (i % 30 == 0) log.mark(i * 200L, "step".repeat(100))
        }
        log.stop()
        assertTrue(log.report().length <= 6000)
        assertTrue(log.report().contains("rawWHXY=30,20,100,80"))
        assertTrue(log.report().contains("end=stopped"))
    }

    @Test fun changingFramesStayBoundedAndKeepLatestTransition() {
        val log = LiveViewFocusDiagnostic()
        log.start(0, "Z30")
        for (i in 0..299) {
            val bytes = ByteArray(515).also { it[42] = (i % 3).toByte() }
            log.sample(LiveViewPacket(bytes, 512, null, i * 200L, 0x9428), "photo")
            if (i % 30 == 0) log.mark(i * 200L, "step")
        }
        log.stop()
        assertTrue(log.report().length <= 6000)
        assertTrue(log.report().contains("+59800"))
        assertTrue(log.report().contains("changes=300"))
    }

    @Test fun uiTransitionsAreRetainedWithoutLoggingEveryDraw() {
        val log = LiveViewFocusDiagnostic()
        log.start(0, "Z30")
        repeat(100) { log.display("drawn boxPx=50x40 centerPx=$it,20") }
        log.display("blocked=no-box none age=10ms")
        repeat(100) { log.display("blocked=no-box none age=${it}ms") }
        assertEquals(2, log.report().lineSequence().count { it.startsWith("UI ") })
        assertTrue(log.report().contains("UI drawn"))
        assertTrue(log.report().contains("UI blocked=no-box"))
        log.stop()
        val report = log.report()
        log.display("drawn boxPx=99x99")
        assertEquals(report, log.report())
    }

}
