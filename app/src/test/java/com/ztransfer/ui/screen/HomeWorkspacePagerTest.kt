package com.ztransfer.ui.screen

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeWorkspacePagerTest {
    @Test
    fun `quick return requires both minimum distance and downward speed`() {
        assertFalse(shouldReturnFromWorkspace(0.14f, 5000f))
        assertFalse(shouldReturnFromWorkspace(0.20f, 1199f))
        assertFalse(shouldReturnFromWorkspace(0.20f, -2000f))
        assertTrue(shouldReturnFromWorkspace(0.15f, 1200f))
        assertTrue(shouldReturnFromWorkspace(0.30f, 0f))
        assertFalse(shouldReturnFromWorkspace(0f, 5000f))
    }

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
    fun `return threshold is easier than entry threshold`() {
        assertTrue(WORKSPACE_RETURN_SNAP_THRESHOLD >= 0.30f)
        assertTrue(WORKSPACE_RETURN_SNAP_THRESHOLD <= 0.35f)
        assertTrue(WORKSPACE_ENTRY_SNAP_THRESHOLD >= 0.40f)
        assertTrue(WORKSPACE_RETURN_SNAP_THRESHOLD < WORKSPACE_ENTRY_SNAP_THRESHOLD)
    }

    @Test
    fun `GPS blocks entering workbench but allows returning to connection page`() {
        assertFalse(
            workspacePagerUserScrollEnabled(
                gpsEnabled = true,
                currentPage = 0,
            )
        )
        assertTrue(
            workspacePagerUserScrollEnabled(
                gpsEnabled = true,
                currentPage = 1,
            )
        )
        assertTrue(
            workspacePagerUserScrollEnabled(
                gpsEnabled = false,
                currentPage = 0,
            )
        )
    }
}
