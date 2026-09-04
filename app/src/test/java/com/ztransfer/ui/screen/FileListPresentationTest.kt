package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.viewmodel.CameraState
import com.ztransfer.connection.StaConnectionStatus
import com.ztransfer.viewmodel.TransferState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class FileListPresentationTest {
    @Test
    fun cameraContentStateIgnoresSignalAndConnectionPageProgress() {
        val initial = CameraState().toFileListCameraUiState()
        val unrelatedUpdate = CameraState(
            wifiRssi = -38,
            staConnectionStatus = StaConnectionStatus.DISCOVERING,
            staDiscoveryProgress = "searching",
        ).toFileListCameraUiState()

        assertEquals(initial, unrelatedUpdate)
        assertNotEquals(
            initial,
            CameraState(isLoadingFiles = true).toFileListCameraUiState(),
        )
    }

    @Test
    fun signalStateTracksOnlyWhatTheSignalPillRenders() {
        val initial = CameraState().toFileListSignalUiState()

        assertNotEquals(
            initial,
            CameraState(wifiRssi = -42).toFileListSignalUiState(),
        )
        assertNotEquals(
            initial,
            CameraState(
                isConnectedToCamera = true,
                connectionType = CameraConnectionType.USB,
            ).toFileListSignalUiState(),
        )
        assertEquals(
            initial,
            CameraState(isLoadingFiles = true).toFileListSignalUiState(),
        )
    }

    @Test
    fun transferContentStateIgnoresSettingsOutsideThePhotoPage() {
        val source = TransferState()
        val initial = source.toFileListTransferUiState()

        assertEquals(
            initial,
            source.copy(
                autoTransferNewMedia = true,
                deferTransferStart = true,
                keepScreenOn = false,
            ).toFileListTransferUiState(),
        )
        assertNotEquals(
            initial,
            source.copy(thumbnailColumns = 4).toFileListTransferUiState(),
        )
    }
}
