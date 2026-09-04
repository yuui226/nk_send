package com.ztransfer.catalog

/** Only null dates use this grouping key; malformed non-null values keep their existing key. */
const val UNKNOWN_CAPTURE_DATE_GROUP_KEY = "zzz_unknown"

data class CameraFileFilter(
    val extensions: Set<String>? = null,
    val protectedOnly: Boolean = false,
    val burstOnly: Boolean = false,
    val untransferredOnly: Boolean = false,
    /** null disables storage filtering; an empty set is an active filter that matches nothing. */
    val selectedStorageIds: Set<Int>? = null,
    val dateRange: CaptureDayRange? = null,
)

/** Applies every active filter with AND semantics while preserving the camera's input order. */
fun <T : CameraCatalogFile> filterCameraFiles(
    files: List<T>,
    criteria: CameraFileFilter,
    burstHandles: Set<Int> = emptySet(),
    transferredHandles: Set<Int> = emptySet(),
): List<T> = files.asSequence()
    .filter { criteria.extensions == null || it.extension in criteria.extensions }
    .filter { !criteria.protectedOnly || it.isProtected }
    .filter { !criteria.burstOnly || it.handle in burstHandles }
    .filter { !criteria.untransferredOnly || it.handle !in transferredHandles }
    .filter { file ->
        criteria.selectedStorageIds == null ||
            criteria.selectedStorageIds.any { storageId -> storageId in file.storageIds }
    }
    .filter { criteria.dateRange == null || criteria.dateRange.containsCaptureDate(it.captureDate) }
    .toList()

data class CameraDateGroup<out T : CameraCatalogFile>(
    val date: String,
    val files: List<T>,
)

/** Stable full-timestamp descending order; equal values retain the camera's natural order. */
fun <T : CameraCatalogFile> newestFirstCameraFiles(files: List<T>): List<T> =
    files.sortedByDescending { it.captureDate.orEmpty() }

/**
 * Preserves the Android list's deliberately loose grouping behavior: only null is unknown, while
 * any non-null value forms a group from its first eight characters. Unknown sorts first because
 * its stable key begins with "zzz" and groups are ordered descending.
 */
fun <T : CameraCatalogFile> groupCameraFilesByDate(files: List<T>): List<CameraDateGroup<T>> {
    val grouped = files.groupBy { it.captureDate?.take(8) ?: UNKNOWN_CAPTURE_DATE_GROUP_KEY }
    return grouped.map { (date, groupFiles) ->
        CameraDateGroup(date = date, files = newestFirstCameraFiles(groupFiles))
    }.sortedByDescending { it.date }
}

/** null means every available slot is selected. */
fun isStorageSlotSelected(selectedSlot: Int?, slot: Int): Boolean =
    selectedSlot == null || selectedSlot == slot

/** A storage-slot filter is meaningful only when at least two distinct slots are available. */
fun storageFilterSlots(availableSlots: Collection<Int>): List<Int> =
    availableSlots.distinct().sorted().takeIf { it.size > 1 }.orEmpty()

/** Keeps an in-progress scan from clearing a selection based on temporarily incomplete data. */
fun normalizeStorageSlotFilter(
    selectedSlot: Int?,
    availableSlots: List<Int>,
    hasCompletedFileScan: Boolean,
): Int? {
    if (selectedSlot == null || !hasCompletedFileScan) return selectedSlot
    return selectedSlot.takeIf { availableSlots.size > 1 && it in availableSlots }
}

/** Toggles one of two camera slots without allowing an active filter to select no slot. */
fun toggleStorageSlotSelection(
    selectedSlot: Int?,
    toggledSlot: Int,
    availableSlots: List<Int>,
): Int? {
    val slots = availableSlots.distinct()
    if (toggledSlot !in slots) return selectedSlot
    return when {
        selectedSlot == null -> slots.singleOrNull { it != toggledSlot }
        selectedSlot == toggledSlot -> selectedSlot
        else -> null
    }
}
