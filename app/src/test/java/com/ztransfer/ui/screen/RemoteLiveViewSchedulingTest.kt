package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.Lab
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.USB_LIVE_VIEW_WARMUP_MS
import com.ztransfer.protocol.liveViewWarmupRemainingMs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteLiveViewSchedulingTest {
    @Test
    fun remoteUsbReopenOnlyYieldsForInterfaceRelease() {
        assertEquals(100L, NikonCamera.USB_REMOTE_REOPEN_SETTLE_MS)
    }

    @Test
    fun usbWarmupOnlyWaitsForTheUncoveredRemainder() {
        assertEquals(
            USB_LIVE_VIEW_WARMUP_MS,
            liveViewWarmupRemainingMs(
                connectionType = CameraConnectionType.USB,
                readyAtElapsedMs = 1_000L,
                nowElapsedMs = 1_000L
            )
        )
        assertEquals(
            250L,
            liveViewWarmupRemainingMs(
                connectionType = CameraConnectionType.USB,
                readyAtElapsedMs = 1_000L,
                nowElapsedMs = 1_500L
            )
        )
        assertEquals(
            0L,
            liveViewWarmupRemainingMs(
                connectionType = CameraConnectionType.USB,
                readyAtElapsedMs = 1_000L,
                nowElapsedMs = 2_000L
            )
        )
    }

    @Test
    fun wifiNeverGetsTheUsbWarmupDelay() {
        assertEquals(
            0L,
            liveViewWarmupRemainingMs(
                connectionType = CameraConnectionType.WIFI,
                readyAtElapsedMs = 1_000L,
                nowElapsedMs = 1_000L
            )
        )
    }

    @Test
    fun movieModePollingContinuesWhileOldLiveViewRecovers() {
        assertTrue(
            shouldPollMovieModeDuringLiveViewRecovery(
                initialLoaded = true,
                liveViewStable = false,
                cameraBusy = false
            )
        )
        assertFalse(
            shouldPollMovieModeDuringLiveViewRecovery(
                initialLoaded = false,
                liveViewStable = false,
                cameraBusy = false
            )
        )
        assertFalse(
            shouldPollMovieModeDuringLiveViewRecovery(
                initialLoaded = true,
                liveViewStable = true,
                cameraBusy = false
            )
        )
        assertFalse(
            shouldPollMovieModeDuringLiveViewRecovery(
                initialLoaded = true,
                liveViewStable = false,
                cameraBusy = true
            )
        )
    }

    @Test
    fun usbComputerControlIsHeldOnlyForAnActualRecordingAttempt() {
        assertTrue(
            shouldPrepareUsbMovieSessionForRecord(
                connectionType = CameraConnectionType.USB,
                remoteControlModeSet = false
            )
        )
        assertFalse(
            shouldPrepareUsbMovieSessionForRecord(
                connectionType = CameraConnectionType.USB,
                remoteControlModeSet = true
            )
        )
        assertFalse(
            shouldPrepareUsbMovieSessionForRecord(
                connectionType = CameraConnectionType.WIFI,
                remoteControlModeSet = false
            )
        )
        assertTrue(
            shouldReturnUsbMovieSessionToStandby(
                connectionType = CameraConnectionType.USB,
                remoteControlModeSet = true
            )
        )
    }

    @Test
    fun startupBatchDropsOnlyPropertyChanges() {
        val objectEvent = Lab.EVT_OBJECT_ADDED to 42L
        val events = listOf(
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
            objectEvent,
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_F_NUMBER.toLong()
        )

        assertEquals(
            listOf(objectEvent),
            coalesceRemoteEvents(events, suppressPropertyChanges = true)
        )
    }

    @Test
    fun steadyBatchDeduplicatesEquivalentLogicalProperties() {
        val objectEvent = Lab.EVT_OBJECT_ADDED to 99L
        val events = listOf(
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXP_COMPENSATION.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_NK_EXP_COMPENSATION.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_NK_ISO_EX.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXPOSURE_TIME_STD.toLong(),
            Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_NK_SHUTTER.toLong(),
            objectEvent
        )

        assertEquals(
            listOf(
                Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXP_COMPENSATION.toLong(),
                Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_ISO.toLong(),
                Lab.EVT_DEVICE_PROP_CHANGED to Lab.PROP_EXPOSURE_TIME_STD.toLong(),
                objectEvent
            ),
            coalesceRemoteEvents(events, suppressPropertyChanges = false)
        )
    }
}
