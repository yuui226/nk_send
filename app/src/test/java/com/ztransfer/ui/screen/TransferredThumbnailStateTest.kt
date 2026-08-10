package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.TransferStatus
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferredThumbnailStateTest {

    @Test
    fun completedTaskUsesTheSameExportedBadgeAsDirectoryScan() {
        assertFalse(showsQueueStatusOverlay(TransferStatus.COMPLETED))
    }

    @Test
    fun unfinishedAndProblemStatesKeepTheirQueueStatusOverlay() {
        assertTrue(showsQueueStatusOverlay(TransferStatus.WAITING))
        assertTrue(showsQueueStatusOverlay(TransferStatus.TRANSFERING))
        assertTrue(showsQueueStatusOverlay(TransferStatus.FAILED))
        assertTrue(showsQueueStatusOverlay(TransferStatus.CANCELLED))
    }
}
