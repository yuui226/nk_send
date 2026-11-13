package com.ztransfer.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StaConnectionDiagnosticsTest {
    @Test
    fun `records relative time and complete attempt until finished`() {
        var now = 1_000L
        val history = StaDiagnosticHistory { now }
        val id = history.begin()
        now += 35L
        history.note(id, "discovery ready")
        now += 40L
        history.attempt(id, "candidate 1", "first line\nlast line\n")
        now += 25L
        history.finish(id, "connected")
        val finished = history.snapshot()
        now += 50L
        history.note(id, "late callback")
        history.attempt(id, "late attempt", "stale")
        history.finish(id, "cancelled")

        assertTrue(finished.contains("+35ms discovery ready"))
        assertTrue(finished.contains("+75ms attempt [candidate 1]\nfirst line\nlast line\n"))
        assertTrue(finished.endsWith("+100ms result=connected"))
        assertEquals(finished, history.snapshot())
    }

    @Test
    fun `new discovery rejects every callback from previous discovery`() {
        val history = StaDiagnosticHistory { 0L }
        val oldId = history.begin()
        history.note(oldId, "old session")
        val newId = history.begin()
        history.note(newId, "current session")
        history.note(oldId, "late old note")
        history.attempt(oldId, "late old attempt", "old report")
        history.finish(oldId, "cancelled")

        val report = history.snapshot()
        assertTrue(report.contains("current session"))
        assertFalse(report.contains("old"))
        assertTrue(report.endsWith("result=running"))
    }

    @Test
    fun `clear invalidates current token and tokens are never reused`() {
        val history = StaDiagnosticHistory { 0L }
        val oldId = history.begin()
        history.clear()
        history.note(oldId, "late after clear")
        assertEquals("暂无 STA 连接记录", history.snapshot())
        val newId = history.begin()
        assertTrue(newId > oldId)
        history.finish(oldId, "cancelled")
        assertTrue(history.snapshot().endsWith("result=running"))
    }

    @Test
    fun `size bound evicts entire attempts without truncating retained ones`() {
        val history = StaDiagnosticHistory { 0L }
        val id = history.begin()
        history.attempt(id, "older", "OLDER_START\n" + "a".repeat(40_000) + "\nOLDER_END")
        val latest = "NEWER_START\n" + "b".repeat(40_000) + "\nNEWER_END"
        history.attempt(id, "newer", latest)
        history.finish(id, "connected")

        val report = history.snapshot()
        assertFalse(report.contains("OLDER_"))
        assertTrue(report.contains(latest))
        assertTrue(report.contains("省略较早记录 1 块"))
        assertTrue(report.length < 66_000)
    }

    @Test
    fun `oversized attempt cannot erase prior useful data or grow memory`() {
        val history = StaDiagnosticHistory { 0L }
        val id = history.begin()
        history.note(id, "useful")
        history.attempt(id, "oversized", "x".repeat(70_000))
        history.finish(id, "failed")

        val report = history.snapshot()
        assertTrue(report.contains("useful"))
        assertTrue(report.contains("省略较早记录 1 块"))
        assertFalse(report.contains("oversized"))
        assertTrue(report.length < 1_000)
    }

    @Test
    fun `tiny records are also count bounded`() {
        val history = StaDiagnosticHistory { 0L }
        val id = history.begin()
        repeat(200) { history.note(id, "event=$it") }
        val report = history.snapshot()
        assertFalse(report.contains("event=39\n"))
        assertTrue(report.contains("event=40\n"))
        assertTrue(report.contains("event=199\n"))
        assertTrue(report.contains("省略较早记录 40 块"))
    }
}
