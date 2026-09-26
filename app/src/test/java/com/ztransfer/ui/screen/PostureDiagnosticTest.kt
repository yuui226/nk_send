package com.ztransfer.ui.screen

import com.ztransfer.protocol.LiveViewPacket
import org.junit.Assert.*
import org.junit.Test

class PostureDiagnosticTest {
    private fun packet(at: Long, operation: Int = 0x9428) = LiveViewPacket(
        byteArrayOf(0x12, 0x34, 0xFF.toByte(), 0xD8.toByte(), 0x66, 0x77), 2, null, at, operation)
    @Test fun boundedCaptureCopiesOnlyHeadersAndRequiresFiveDistinctSteps() {
        val capture = PostureDiagnostic()
        val camera = Any()
        repeat(5) { pose ->
            val start = pose * 3000L
            assertTrue(capture.begin(camera, "test", start))
            for (i in 0..200) {
                val p = packet(start + i * 10)
                capture.offer(camera, p)
                p.bytes[0] = 0 // Captured data must not alias the packet.
            }
            assertTrue(capture.finish())
        }
        val report = capture.report()
        assertTrue(report.contains("completed=5/5"))
        assertEquals(40, report.lineSequence().count { it == "1234" })
        assertFalse(report.contains("ffd8"))
        assertFalse(capture.begin(camera, "test", 20000))
    }
    @Test fun rejectsInsufficientFramesProtocolChangesAndDifferentCamera() {
        val c = PostureDiagnostic(); val camera = Any()
        c.begin(camera, "test", 100)
        c.offer(camera, packet(99))
        assertFalse(c.finish())
        c.begin(camera, "test", 100)
        repeat(8) { c.offer(camera, packet(100L + it * 250, if (it == 7) 0x9203 else 0x9428)) }
        assertFalse(c.finish())
        c.begin(camera, "test", 100)
        repeat(8) { c.offer(camera, packet(100L + it * 250)) }
        c.offer(Any(), packet(2000))
        assertFalse(c.finish())
        assertFalse(c.begin(Any(), "test", 3000))
        c.reset()
        assertTrue(c.begin(camera, "new mode", 3000))
        c.cancel()
        repeat(8) { c.offer(camera, packet(3000L + it * 250)) }
        assertFalse(c.finish())
    }
}
