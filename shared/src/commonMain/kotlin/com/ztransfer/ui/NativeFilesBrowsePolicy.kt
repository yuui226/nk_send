package com.ztransfer.ui

import com.ztransfer.catalog.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.SharedPhotoFilterCriteria

/** Same field mapping used by Android FileListScreen; the filtering/order algorithms stay shared. */
internal fun nativeFilteredCameraFiles(
    files: List<CameraFileInfo>, storageIds: List<Int>, criteria: SharedPhotoFilterCriteria<CaptureDayRange>,
    burstHandles: Set<Int>, transferredHandles: Set<Int>,
): List<CameraFileInfo> = filterCameraFiles(
    files = files,
    criteria = CameraFileFilter(
        extensions = criteria.extensions, protectedOnly = criteria.protectedOnly,
        burstOnly = criteria.burstOnly, untransferredOnly = criteria.untransferredOnly,
        selectedStorageIds = if (criteria.storageSlot == null) null else storageIdsBySlot(storageIds)[criteria.storageSlot].orEmpty(),
        dateRange = criteria.dateRange,
    ),
    burstHandles = burstHandles, transferredHandles = transferredHandles,
)
