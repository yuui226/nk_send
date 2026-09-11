package com.ztransfer.ui.screen

import com.ztransfer.connection.StaConnectionStatus
import com.ztransfer.connection.WifiConnectionStatus
import com.ztransfer.connection.WirelessMode
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.viewmodel.CameraState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeConnectionPresentationTest {
    @Test
    fun connectionMapperPreservesEverySharedPresentationField() {
        val source = CameraState(
            isConnectedToCamera = true,
            connectionType = CameraConnectionType.WIFI,
            wirelessMode = WirelessMode.STA,
            isStaConnection = true,
            staConnectionStatus = StaConnectionStatus.FAILED,
            staConnectionError = "STA failed",
            usbConnectionError = "USB failed",
            wifiConnectionStatus = WifiConnectionStatus.RECONNECTING,
        )

        assertEquals(
            HomeConnectionUiState(
                isConnectedToCamera = true,
                connectionType = CameraConnectionType.WIFI,
                wirelessMode = WirelessMode.STA,
                isStaConnection = true,
                staConnectionStatus = StaConnectionStatus.FAILED,
                staConnectionError = "STA failed",
                usbConnectionError = "USB failed",
                wifiConnectionStatus = WifiConnectionStatus.RECONNECTING,
            ),
            source.toHomeConnectionUiState(),
        )
    }

    @Test
    fun staConnectButtonBreathingIsSmoothAndPeriodic() {
        assertEquals(0f, staButtonBreathProgress(-1L), 0.001f)
        assertEquals(0f, staButtonBreathProgress(0L), 0.001f)
        assertEquals(0.5f, staButtonBreathProgress(450L), 0.001f)
        assertEquals(1f, staButtonBreathProgress(900L), 0.001f)
        assertEquals(0.5f, staButtonBreathProgress(1_350L), 0.001f)
        assertEquals(0f, staButtonBreathProgress(1_800L), 0.001f)
    }

    @Test
    fun connectionCelebrationUsesOneContinuousTimeline() {
        assertEquals(0f, connectionHeroProgress(-1L), 0f)
        assertEquals(0.5f, connectionHeroProgress(310L), 0.001f)
        assertEquals(1f, connectionHeroProgress(620L), 0f)
        assertEquals(1f, connectionHeroProgress(10_000L), 0f)

        assertEquals(0f, connectionSuccessProgress(499L), 0f)
        assertEquals(0f, connectionSuccessProgress(500L), 0f)
        assertEquals(1f, connectionSuccessProgress(1_260L), 0f)
    }

    @Test
    fun freeConnectionPulsesAreStaggeredAndDisappearCompletely() {
        assertEquals(0f, freeConnectionPulseVisibility(-1f), 0f)
        assertEquals(0f, freeConnectionPulseVisibility(0f), 0f)
        assertTrue(freeConnectionPulseVisibility(0.10f) > 0f)
        assertTrue(freeConnectionPulseVisibility(0.50f) > 0f)
        assertEquals(0f, freeConnectionPulseVisibility(1f), 0f)
        assertEquals(0f, freeConnectionPulseVisibility(2f), 0f)

        assertTrue(freeConnectionPulseProgress(0.10f, 0) > 0f)
        assertEquals(0f, freeConnectionPulseProgress(0.10f, 1), 0f)
        assertTrue(freeConnectionPulseProgress(0.20f, 1) > 0f)
        assertEquals(
            0f,
            freeConnectionPulseVisibility(freeConnectionPulseProgress(1f, 0)),
            0f,
        )
        assertEquals(
            0f,
            freeConnectionPulseVisibility(freeConnectionPulseProgress(1f, 1)),
            0f,
        )
    }

    @Test
    fun albumScanChangesDoNotInvalidateConnectionPresentation() {
        val initial = CameraState().toHomeConnectionUiState()
        val scanning = CameraState(
            isLoadingFiles = true,
            hasCompletedFileScan = true,
            storageIds = listOf(0x00010001),
        ).toHomeConnectionUiState()

        assertEquals(initial, scanning)
        assertTrue(
            initial != CameraState(
                isConnectedToCamera = true,
                connectionType = CameraConnectionType.WIFI,
            ).toHomeConnectionUiState(),
        )
    }

    @Test
    fun subscriptionExpiryNoticeUsesTheOriginalSevenDayWindow() {
        assertFalse(shouldShowSubscriptionExpiryNotice(isPro = true, daysLeft = 8))
        assertTrue(shouldShowSubscriptionExpiryNotice(isPro = true, daysLeft = 7))
        assertTrue(shouldShowSubscriptionExpiryNotice(isPro = true, daysLeft = 0))
        assertFalse(shouldShowSubscriptionExpiryNotice(isPro = false, daysLeft = 7))
    }
}
