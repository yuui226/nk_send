package com.ztransfer.ui

import com.ztransfer.catalog.CaptureDayRange
import com.ztransfer.ui.screen.SharedPhotoFilterCriteria
import com.ztransfer.ui.screen.previewFloorMod
import com.ztransfer.viewmodel.normalizeThumbnailColumns

/** Plain Apple persistence boundary. No camera slot, task, identity or secret is persisted here. */
class NativeBrowsePreferences(
    columns: Int, val collapseBursts: Boolean, extensions: List<String>?,
    val protectedOnly: Boolean, val burstOnly: Boolean, val untransferredOnly: Boolean,
    startDay: Int, endDay: Int,
    previewRotationQuarterTurns: Int, val previewHistogramEnabled: Boolean, val tapToPreview: Boolean,
) {
    /** Keep both existing Apple initializers callable while v1 gains an optional interaction field. */
    constructor(columns: Int, collapseBursts: Boolean, extensions: List<String>?,
        protectedOnly: Boolean, burstOnly: Boolean, untransferredOnly: Boolean, startDay: Int, endDay: Int,
        previewRotationQuarterTurns: Int, previewHistogramEnabled: Boolean,
    ) : this(columns, collapseBursts, extensions, protectedOnly, burstOnly, untransferredOnly,
        startDay, endDay, previewRotationQuarterTurns, previewHistogramEnabled, false)

    /** Preserve the existing eight-field Apple initializer and its original defaults. */
    constructor(columns: Int, collapseBursts: Boolean, extensions: List<String>?,
        protectedOnly: Boolean, burstOnly: Boolean, untransferredOnly: Boolean, startDay: Int, endDay: Int,
    ) : this(columns, collapseBursts, extensions, protectedOnly, burstOnly, untransferredOnly, startDay, endDay, 0, false)

    val previewRotationQuarterTurns: Int = previewFloorMod(previewRotationQuarterTurns, 4)
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

internal data class NativeBrowseLayout(val columns: Int = 3, val collapseBursts: Boolean = true, val tapToPreview: Boolean = false)
internal data class NativePreviewOptions(val rotationQuarterTurns: Int = 0, val histogramEnabled: Boolean = false)
