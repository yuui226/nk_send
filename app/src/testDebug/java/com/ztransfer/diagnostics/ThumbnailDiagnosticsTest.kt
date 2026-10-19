package com.ztransfer.diagnostics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ThumbnailDiagnosticsTest {
    @Before
    fun reset() {
        ThumbnailDiagnostics.beginSession("test-camera")
    }

    @Test
    fun `later successful thumbnails do not evict a failure`() {
        ThumbnailDiagnostics.note("missing.NEF decode failed", failure = true)
        repeat(200) { ThumbnailDiagnostics.note("success-$it.JPG decoded") }

        val report = ThumbnailDiagnostics.snapshot()
        assertTrue(report.contains("missing.NEF decode failed"))
        assertTrue(report.contains("success-199.JPG decoded"))
        assertFalse(report.contains("success-0.JPG decoded"))
        assertEquals(48, report.lineSequence().count { it.startsWith("event ") })
    }

    @Test
    fun `large multilingual messages keep the report bounded and one line each`() {
        repeat(100) {
            ThumbnailDiagnostics.note("failure-$it\n" + "图片".repeat(400), failure = true)
            ThumbnailDiagnostics.note("success-$it\r\n" + "图片".repeat(400))
        }

        val report = ThumbnailDiagnostics.snapshot()
        assertTrue(report.toByteArray(Charsets.UTF_8).size < 16 * 1024)
        assertTrue(report.contains("failure-99 图片"))
        assertTrue(report.contains("success-99 图片"))
        assertFalse(report.contains('\r'))
        assertTrue(report.lineSequence().count { it.startsWith("failed ") } <= 24)
        assertTrue(report.lineSequence().count { it.startsWith("event ") } <= 48)
        assertFalse(report.lineSequence().any { it.startsWith("图片") })
    }

    @Test
    fun `clear and a new camera session discard old records`() {
        ThumbnailDiagnostics.note("old-failure", failure = true)
        ThumbnailDiagnostics.note("old-success")
        ThumbnailDiagnostics.clear()
        assertFalse(ThumbnailDiagnostics.snapshot().contains("old-"))
        assertTrue(ThumbnailDiagnostics.snapshot().contains("test-camera"))

        ThumbnailDiagnostics.note("another-failure", failure = true)
        ThumbnailDiagnostics.beginSession("new-camera")
        val report = ThumbnailDiagnostics.snapshot()
        assertTrue(report.contains("new-camera"))
        assertFalse(report.contains("test-camera"))
        assertFalse(report.contains("another-failure"))
    }
}
