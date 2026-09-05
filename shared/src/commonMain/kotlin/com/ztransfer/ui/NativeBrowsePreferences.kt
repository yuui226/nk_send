package com.ztransfer.ui

import com.ztransfer.catalog.CaptureDayRange
import com.ztransfer.ui.screen.SharedPhotoFilterCriteria
import com.ztransfer.viewmodel.normalizeThumbnailColumns

/** Plain Apple persistence boundary. No camera slot, task, identity or secret is persisted here. */
class NativeBrowsePreferences(
    columns: Int, val collapseBursts: Boolean, extensions: List<String>?,
    val protectedOnly: Boolean, val burstOnly: Boolean, val untransferredOnly: Boolean,
    startDay: Int, endDay: Int,
) {
    val columns: Int = normalizeThumbnailColumns(columns)
    val extensions: List<String>? = extensions?.distinct()?.toList()
    private val range = try {
        CaptureDayRange.between(startDay, endDay)
    } catch (_: IllegalArgumentException) { null }
    val startDay: Int get() = range?.startDayKey ?: 0
    val endDay: Int get() = range?.endInclusiveDayKey ?: 0
    internal fun criteria() = SharedPhotoFilterCriteria(
        extensions = extensions?.toSet(), protectedOnly = protectedOnly, burstOnly = burstOnly,
        untransferredOnly = untransferredOnly, dateRange = range,
    )
    companion object {
        // Match TransferViewModel's actual preferences restore, not its pre-restore transient state.
        fun defaults() = NativeBrowsePreferences(3, true, null, false, false, false, 0, 0)
    }
}

internal data class NativeBrowseLayout(val columns: Int = 3, val collapseBursts: Boolean = true)
