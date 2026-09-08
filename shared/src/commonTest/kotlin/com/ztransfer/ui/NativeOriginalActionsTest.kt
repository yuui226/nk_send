package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import kotlin.test.*

class NativeOriginalActionsTest {
    private class Platform : NativeOriginalActionsPlatform {
        var calls = 0
        var closed = false
        lateinit var callback: NativeOriginalActionCompletion
        var received = emptyList<NativeOriginalActionItem>()
        override fun performOriginalAction(action: String, items: List<NativeOriginalActionItem>, completion: NativeOriginalActionCompletion) {
            calls++; received = items; callback = completion
        }
        override fun cancelOriginalActions() { closed = true }
    }
    private fun items() = (1..3).map { NativeOriginalActionItem(CameraFileInfo(it, 4, "PHOTO_$it.JPG", null), "file:///$it") }
    @Test fun partialPhotosReceiptRemovesOnlyConfirmedSelectionsAndDoesNotRetry() {
        val p = Platform(); val m = NativeOriginalActionsModel(); m.attach(p)
        val files = items()
        assertTrue(m.perform("photos", files))
        assertFalse(m.perform("photos", files))
        assertTrue(m.state.value.busy)
        p.callback.complete(intArrayOf(0, 2), 1, false, "real receipt")
        assertEquals(setOf(files[0].locator, files[2].locator), m.state.value.succeeded)
        assertEquals(1, m.state.value.failedCount)
        assertEquals(1, p.calls)
        val result = m.state.value
        p.callback.complete(intArrayOf(1), 0, false, "duplicate")
        assertEquals(result, m.state.value)
    }
    @Test fun frozenIdentityAndOrderSurviveCallerMutation() {
        val p = Platform(); val m = NativeOriginalActionsModel(); m.attach(p)
        val files = items().toMutableList()
        m.perform("files", files); files.clear()
        assertEquals(listOf(1, 2, 3), p.received.map { it.file.handle })
        p.callback.complete(intArrayOf(), 0, true, null)
        assertTrue(m.state.value.cancelled)
        assertTrue(m.state.value.succeeded.isEmpty())
    }
    @Test fun invalidOrDuplicateReceiptsCannotManufactureSuccess() {
        val p = Platform(); val m = NativeOriginalActionsModel(); m.attach(p)
        m.perform("share", items())
        p.callback.complete(intArrayOf(0, 0), 0, false, null)
        assertTrue(m.state.value.succeeded.isEmpty()); assertEquals(3, m.state.value.failedCount)
        assertFalse(m.perform("delete", items()))
        assertFalse(m.perform("photos", List(501) { items()[0] }))
        m.close()
        assertTrue(p.closed); assertFalse(m.perform("share", items()))
    }
    @Test fun closureAndOldReceiptDoNotOverwriteNextOperation() {
        val p = Platform(); val m = NativeOriginalActionsModel(); m.attach(p)
        m.perform("photos", items()); val old = p.callback
        old.complete(intArrayOf(), 0, true, null)
        m.perform("files", items())
        old.complete(intArrayOf(0, 1, 2), 0, false, "late")
        assertTrue(m.state.value.busy)
        m.close(); p.callback.complete(intArrayOf(0), 2, false, null)
        assertFalse(m.state.value.busy); assertTrue(m.state.value.succeeded.isEmpty())
    }
}
