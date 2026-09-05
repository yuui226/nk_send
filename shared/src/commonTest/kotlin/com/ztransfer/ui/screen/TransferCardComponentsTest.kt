package com.ztransfer.ui.screen

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.skinAppColors
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlin.test.Test
import kotlin.test.assertEquals

class TransferCardComponentsTest {
    private val file = CameraFileInfo(1, 1024, "DSC_0001.JPG", "20260905T120000")

    @Test fun everyTaskStatusKeepsOriginalSemanticColorForEverySkinAndMode() {
        for (skin in SkinPreset.entries) for (dark in listOf(false, true)) {
            val colors = skinAppColors(skin, dark)
            for (status in TransferStatus.entries) {
                val expected = when (status) {
                    TransferStatus.WAITING -> colors.accentYellow
                    TransferStatus.TRANSFERING -> colors.accentBlue
                    TransferStatus.COMPLETED -> colors.statusConnected
                    TransferStatus.FAILED -> colors.statusError
                    TransferStatus.CANCELLED -> colors.onSurfaceVariant
                }
                assertEquals(expected, transferCardStateColor(TransferTask(file, 7, status = status), colors))
            }
        }
    }

    @Test fun generationFlagRetainsPriorityEvenForConflictingFailureOrCancellation() {
        val colors = skinAppColors(SkinPreset.FROSTED_GLASS, false)
        TransferStatus.entries.forEach { status ->
            val task = TransferTask(file, 8, status = status, isGeneratingFrame = true)
            assertEquals(colors.accentPurple, transferCardStateColor(task, colors))
            assertEquals(status, task.status)
        }
    }
}
