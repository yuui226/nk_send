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

    @Test
    fun `workspace is released only when a real camera connection starts`() {
        assertFalse(shouldReleaseLocalWorkspace(isConnecting = false, isConnected = false))
        assertTrue(shouldReleaseLocalWorkspace(isConnecting = true, isConnected = false))
        assertTrue(shouldReleaseLocalWorkspace(isConnecting = false, isConnected = true))
        assertTrue(shouldReleaseLocalWorkspace(isConnecting = true, isConnected = true))
    }

    @Test
    fun `only the return direction uses the more responsive snap threshold`() {
        assertTrue(WORKSPACE_RETURN_SNAP_THRESHOLD >= 0.15f)
        assertTrue(WORKSPACE_RETURN_SNAP_THRESHOLD <= 0.25f)
        assertTrue(WORKSPACE_ENTRY_SNAP_THRESHOLD >= 0.40f)
        assertTrue(WORKSPACE_RETURN_SNAP_THRESHOLD < WORKSPACE_ENTRY_SNAP_THRESHOLD)
    }
}
