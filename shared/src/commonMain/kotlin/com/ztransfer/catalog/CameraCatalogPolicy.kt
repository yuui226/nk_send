package com.ztransfer.catalog

/** Filters camera storage identifiers without changing Android's signed ordering semantics. */
fun usableStorageIds(rawIds: List<Int>, isStaConnection: Boolean): List<Int> = rawIds
    .filter { storageId ->
        if (isStaConnection) storageId != 0 && storageId != -1
        else storageId and 0xFFFF != 0
    }
    .distinct()
    .sorted()

/** Paired Nikon STA exposes an aggregate store through wildcard object enumeration. */
fun objectHandleQueryStorageId(storageId: Int, isStaConnection: Boolean): Int =
    if (isStaConnection && storageId and 0xFFFF == 0) -1 else storageId

data class CameraHandleDelta(
    val added: Set<Int>,
    val removed: Set<Int>,
)

/** Difference between two complete and successful GetObjectHandles snapshots. */
fun cameraHandleDelta(
    knownHandles: Set<Int>,
    currentHandles: Set<Int>,
): CameraHandleDelta = CameraHandleDelta(
    added = currentHandles - knownHandles,
    removed = knownHandles - currentHandles,
)

/** Stable logical identity used to collapse dual-card backup aliases into one visible row. */
fun cameraFileLogicalIdentity(
    fileName: String,
    size: Long,
    captureDate: String?,
): String = "$fileName|$size|$captureDate"

/** Preserves the existing set instance when the duplicate adds no new storage membership. */
fun mergeStorageIds(existing: Set<Int>, duplicate: Set<Int>): Set<Int> =
    if (duplicate.all(existing::contains)) existing else existing + duplicate

/**
 * Selects between two present per-card catalog heads. A missing capture date is deliberately
 * released first so it cannot block newer dated files behind it; equal values keep card order.
 */
fun isCameraFileHeadPreferred(
    candidateCaptureDate: String?,
    selectedCaptureDate: String?,
): Boolean = when {
    candidateCaptureDate == null && selectedCaptureDate != null -> true
    candidateCaptureDate != null && selectedCaptureDate == null -> false
    candidateCaptureDate == null -> false
    else -> candidateCaptureDate > checkNotNull(selectedCaptureDate)
}

/**
 * Maps PTP StorageIDs to physical card slots. Standard physical and low-word slot identifiers are
 * preferred; non-standard physical groups fill remaining slots in stable signed-ID order.
 */
fun storageIdsBySlot(storageIds: List<Int>): Map<Int, Set<Int>> {
    val assigned = mutableMapOf<Int, MutableSet<Int>>()
    val unassignedGroups = linkedMapOf<Int, MutableSet<Int>>()
    storageIds.distinct().sorted().forEach { storageId ->
        val physical = storageId ushr 16 and 0xFFFF
        val logical = storageId and 0xFFFF
        val slot = when {
            physical in 1..2 -> physical
            physical == 0 && logical in 1..2 -> logical
            else -> null
        }
        if (slot != null) {
            assigned.getOrPut(slot) { linkedSetOf() } += storageId
        } else {
            val groupKey = if (physical == 0) storageId else physical
            unassignedGroups.getOrPut(groupKey) { linkedSetOf() } += storageId
        }
    }
    unassignedGroups.values.forEach { ids ->
        val freeSlot = (1..2).firstOrNull { it !in assigned } ?: return@forEach
        assigned[freeSlot] = ids
    }
    return buildMap {
        (1..2).forEach { slot ->
            assigned[slot]?.let { ids -> put(slot, ids.toSet()) }
        }
    }
}

/** One camera response containing the raw, oldest-to-newest handles for a storage identifier. */
data class StorageHandleBatch(
    val storageId: Int,
    val handles: List<Int>,
)

/** One storage identifier's handles in the order in which file metadata must be read. */
data class StorageHandleOrder(
    val storageId: Int,
    val newestFirstHandles: List<Int>,
)

/**
 * Reverses each camera-provided list without numeric sorting. Duplicate handles across cards remain
 * only in the first storage batch, preserving the camera's media interleave and storage priority.
 */
fun newestFirstHandleOrders(
    rawHandlesByStorage: List<StorageHandleBatch>,
): List<StorageHandleOrder> {
    val seen = HashSet<Int>()
    return rawHandlesByStorage.map { batch ->
        StorageHandleOrder(
            storageId = batch.storageId,
            newestFirstHandles = batch.handles.asReversed().filter(seen::add),
        )
    }
}

data class StaDirectStorageLayout(
    val storageIdsByHandle: Map<Int, Set<Int>>,
    val filterStorageIds: List<Int>,
    val crossSlotOverlapCount: Int,
)

/**
 * Derives direct-STA membership from per-storage handle responses. If any handle spans physical
 * slots, the camera is treating the selectors as aliases and storage filtering is disabled.
 */
fun analyzeStaDirectStorageLayout(
    rawHandlesByStorage: List<StorageHandleBatch>,
): StaDirectStorageLayout {
    val storageIds = rawHandlesByStorage.map(StorageHandleBatch::storageId).distinct().sorted()
    val slotByStorageId = buildMap {
        storageIdsBySlot(storageIds).forEach { (slot, ids) ->
            ids.forEach { storageId -> put(storageId, slot) }
        }
    }
    val observedStorageIds = LinkedHashMap<Int, MutableSet<Int>>()
    rawHandlesByStorage.forEach { batch ->
        batch.handles.forEach { handle ->
            observedStorageIds.getOrPut(handle) { linkedSetOf() } += batch.storageId
        }
    }
    val crossSlotOverlapCount = observedStorageIds.values.count { memberships ->
        memberships.mapNotNull(slotByStorageId::get).distinct().size > 1
    }
    val reliable = crossSlotOverlapCount == 0
    return StaDirectStorageLayout(
        storageIdsByHandle = if (reliable) {
            observedStorageIds.mapValues { (_, ids) -> ids.toSet() }
        } else {
            emptyMap()
        },
        filterStorageIds = if (reliable) storageIds else emptyList(),
        crossSlotOverlapCount = crossSlotOverlapCount,
    )
}
