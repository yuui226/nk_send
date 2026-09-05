package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.transferDestinationFolderName

/** Manual-original transfer options. No target grant, queue state or unfinished auto-event switch. */
data class NativeTransferPreferences(val organizeByDate: Boolean, val deferStart: Boolean) {
    fun destinationFolder(file: CameraFileInfo, dayKey: Int): String? =
        transferDestinationFolderName(file.captureDate, organizeByDate, dayKey)

    companion object {
        fun defaults() = NativeTransferPreferences(organizeByDate = false, deferStart = false)
    }
}
