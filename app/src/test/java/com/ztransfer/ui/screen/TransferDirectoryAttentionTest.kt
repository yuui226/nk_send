package com.ztransfer.ui.screen

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferDirectoryAttentionTest {
    @Test
    fun blockedActionHighlightsMissingDirectory() {
        assertTrue(
            transferDirectoryNeedsAttention(
                requested = true,
                isDirectorySet = false,
            )
        )
    }

    @Test
    fun configuredDirectoryStopsAttentionImmediately() {
        assertFalse(
            transferDirectoryNeedsAttention(
                requested = true,
                isDirectorySet = true,
            )
        )
    }

    @Test
    fun ordinarySettingsOpenDoesNotPulse() {
        assertFalse(
            transferDirectoryNeedsAttention(
                requested = false,
                isDirectorySet = false,
            )
        )
    }
}
