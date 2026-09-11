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
 * any non-null value forms a group from its first eight characters. Unknown sorts before valid
 * yyyyMMdd keys because its stable key begins with "zzz" and groups are ordered descending.
 */
fun <T : CameraCatalogFile> groupCameraFilesByDate(files: List<T>): List<CameraDateGroup<T>> {
    val grouped = files.groupBy { it.captureDate?.take(8) ?: UNKNOWN_CAPTURE_DATE_GROUP_KEY }
    return grouped.map { (date, groupFiles) ->
        CameraDateGroup(date = date, files = newestFirstCameraFiles(groupFiles))
    }.sortedByDescending { it.date }
}

data class CameraBurstGroup<out T : CameraCatalogFile>(
    val id: String,
    val files: List<T>,
)

/**
 * Detects existing Android burst runs without tightening its intentionally permissive PTP parsing.
 * Tracks are separated by normalized extension, then ordered by date prefix and trailing file
 * number. Three or more consecutive numbers captured zero or one second apart form a burst.
 */
fun <T : CameraCatalogFile> detectCameraBurstGroups(files: List<T>): List<CameraBurstGroup<T>> {
    if (files.size < 3) return emptyList()

    class Shot<T : CameraCatalogFile>(
        val file: T,
        val number: Int,
        val daySecond: Int,
        val date: String,
    )

    val result = ArrayList<CameraBurstGroup<T>>()
    files.groupBy { it.extension }.forEach { (extension, group) ->
        val shots = group.mapNotNull { file ->
            val captureDate = file.captureDate ?: return@mapNotNull null
            if (captureDate.length < 15 ||
                !captureDate.substring(9, 15).all { it.isDigit() }
            ) {
                return@mapNotNull null
            }
            val daySecond = captureDate.substring(9, 11).toInt() * 3600 +
                captureDate.substring(11, 13).toInt() * 60 +
                captureDate.substring(13, 15).toInt()
            val dot = file.fileName.lastIndexOf('.')
            val stem = if (dot < 0) file.fileName else file.fileName.substring(0, dot)
            val digits = stem.takeLastWhile { it.isDigit() }
            if (digits.isEmpty() || digits.length > 9) return@mapNotNull null
            Shot(file, digits.toInt(), daySecond, captureDate.substring(0, 8))
        }.sortedWith(compareBy({ it.date }, { it.number }))

        var runStart = 0
        for (index in 1..shots.size) {
            val timeGap = if (index < shots.size) {
                shots[index].daySecond - shots[index - 1].daySecond
            } else {
                Int.MAX_VALUE
            }
            val broke = index == shots.size ||
                shots[index].date != shots[index - 1].date ||
                shots[index].number != shots[index - 1].number + 1 ||
                timeGap !in 0..1
            if (broke) {
                if (index - runStart >= 3) {
                    val first = shots[runStart]
                    result += CameraBurstGroup(
                        id = "${extension}_${first.date}_${first.number}_${first.file.handle}",
                        files = shots.subList(runStart, index).map { it.file },
                    )
                }
                runStart = index
            }
        }
    }
    return result
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
