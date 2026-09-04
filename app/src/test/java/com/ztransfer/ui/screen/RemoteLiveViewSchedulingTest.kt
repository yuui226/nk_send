package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteLiveViewSchedulingTest {
    @Test
    fun remoteUsbReopenOnlyYieldsForInterfaceRelease() {
        assertEquals(100L, NikonCamera.USB_REMOTE_REOPEN_SETTLE_MS)
    }
}
