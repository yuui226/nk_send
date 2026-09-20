package com.ztransfer.ui.screen

import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.RcParam
import org.junit.Assert.*
import org.junit.Test

class RemoteDiagnosticReportTest {
    @Test
    fun retainsStartupAndReleaseFailuresWhileIgnoringFrameStatistics() {
        listOf(
            "!! DeviceReady(0x90C8) resp=0x2019 after 4000ms",
            "!! LV prohibit condition = 0x00000001",
            "!! LV: connection reset",
            "!! ChangeApplicationMode(0) resp=0x2019",
            "control mode exit SetControlMode(0) resp=0x2001",
            "EndLiveView resp=0x2001",
            "LiveView first frame received after 130ms",
            "shutter write prop=0xD100 target=65736 confirmed=false read=unreadable resp=0xFFFF",
            "diagnostic camera=NIKON Z f firmware=1.00 transport=WIFI wifiMode=STA"
        ).forEach { assertTrue(it, isRemoteDiagnosticLine(it)) }
        assertFalse(isRemoteDiagnosticLine("LV USB IO: 30.0fps polls=30 busy=0 err=0 avg=30ms"))
    }

    @Test
    fun longReportsKeepBaselineAndLatestFailureWithinClipboardBudget() {
        val lines = mutableListOf<String>()
        repeat(40) { appendRemoteDiagnosticLine(lines, "baseline-$it") }
        repeat(700) { appendRemoteDiagnosticLine(lines, "capability-$it " + "x".repeat(1_900)) }
        appendRemoteDiagnosticLine(lines, "!! control mode release failed")
        assertEquals((0 until 40).map { "baseline-$it" }, lines.take(40))
        assertEquals("!! control mode release failed", lines.last())
        assertTrue(lines.any { "entries omitted" in it })
        assertTrue(lines.size <= 300)
        assertTrue(lines.joinToString("\n").length <= 96_000)
    }

    @Test
    fun shortReportsRoundTripWithoutLosingAnyLines() {
        val original = mutableListOf<String>()
        repeat(100) { appendRemoteDiagnosticLine(original, "diagnostic-$it") }
        val restored = mutableListOf<String>()
        original.joinToString("\n").lineSequence().forEach { appendRemoteDiagnosticLine(restored, it) }
        assertEquals(original, restored)
    }

    @Test
    fun modeAckAloneDoesNotMeanShutterCanBeAdjusted() {
        val locked = RcParam(Lab.PROP_NK_SHUTTER, 6, false, 65736L, listOf(65736L))
        assertFalse(canTryRemoteShutter(null))
        assertFalse(canTryRemoteShutter(locked))
        assertFalse(canTryRemoteShutter(locked.copy(writable = true)))
        assertFalse(canTryRemoteShutter(locked.copy(writable = true, values = emptyList())))
        assertTrue(canTryRemoteShutter(locked.copy(writable = true, values = listOf(65736L, 65636L))))
    }
}
