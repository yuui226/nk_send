package com.ztransfer.ui

import androidx.compose.runtime.mutableStateMapOf
import com.ztransfer.catalog.CaptureDayRange
import com.ztransfer.ui.screen.SharedPhotoFilterCriteria

/** In-memory navigation state for ONE connection, never a preferences or identity document. */
class NativeBrowseSession(val connectionId: String) {
    internal var criteria = SharedPhotoFilterCriteria<CaptureDayRange>()
    internal val collapsedDates = mutableStateMapOf<String, Boolean>()
    internal val expandedBursts = mutableStateMapOf<String, Boolean>()
    internal var firstVisibleIndex = 0
    internal var firstVisibleOffset = 0
    internal var anchorHandle: Int? = null
    internal var initialized = false
}
