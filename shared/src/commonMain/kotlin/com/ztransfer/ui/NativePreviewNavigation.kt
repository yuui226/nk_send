package com.ztransfer.ui

import com.ztransfer.ui.screen.*
import kotlin.math.abs

/** The original grid ordering is also the preview ordering; no independent album sort. */
internal fun nativePreviewItems(groups: List<FileGroup>, burstIds: Map<Int, String>,
    collapseBursts: Boolean, expanded: Set<String>): List<PhotoPreviewItem> = groups.flatMap { group ->
    buildThumbnailGridItems(group.files, burstIds, collapseBursts, expanded).map { item ->
        when (item) {
            is ThumbnailGridItem.Photo -> PhotoPreviewItem.Photo(item.file, item.burstId)
            is ThumbnailGridItem.BurstCollection -> PhotoPreviewItem.BurstCollection(item.id, item.files)
        }
    }
}

/** Lazy indices include date headers, but not children hidden by a collapsed date. */
internal fun nativePreviewGridIndex(handle: Int, groups: List<FileGroup>, burstIds: Map<Int, String>,
    collapseBursts: Boolean, expanded: Set<String>, collapsedDates: Set<String>): Int? {
    var index = 0
    for (group in groups) {
        index++
        if (group.date in collapsedDates) continue
        for (item in buildThumbnailGridItems(group.files, burstIds, collapseBursts, expanded)) {
            if (item is ThumbnailGridItem.Photo && item.file.handle == handle) return index
            index++
        }
    }
    return null
}

/** Same three-row runway and six-row jump threshold as the Android file page. */
internal fun nativePreviewScrollApproach(target: Int, current: Int, columns: Int): Int? {
    val runway = columns.coerceIn(1, 4) * 3
    return if (abs(target - current) > runway * 2) {
        if (target > current) (target - runway).coerceAtLeast(0) else target + runway
    } else null
}
