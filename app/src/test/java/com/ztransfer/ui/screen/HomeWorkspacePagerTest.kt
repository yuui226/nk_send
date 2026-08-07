package com.ztransfer.ui.screen

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeWorkspacePagerTest {
    @Test
    fun `camera discovery pauses for the whole trip to and from local effects`() {
        assertFalse(shouldPauseConnectionDiscovery(settledPage = 0, targetPage = 0))
        assertTrue(shouldPauseConnectionDiscovery(settledPage = 0, targetPage = 1))
        assertTrue(shouldPauseConnectionDiscovery(settledPage = 1, targetPage = 1))
        assertTrue(shouldPauseConnectionDiscovery(settledPage = 1, targetPage = 0))
        assertFalse(shouldPauseConnectionDiscovery(settledPage = 0, targetPage = 0))
    }
}
