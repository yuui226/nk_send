package com.ztransfer.ui.screen

import com.ztransfer.protocol.NikonCamera

internal const val UNKNOWN_DATE_KEY = "zzz_unknown"

internal data class PublishedCameraFileIdentity(
    val fileName: String,
    val size: Long,
    val captureDate: String?,
)

internal fun NikonCamera.FileInfo.publishedIdentity() = PublishedCameraFileIdentity(
    fileName = fileName,
    size = size,
    captureDate = captureDate,
)

internal data class PhotoCatalogChanges(
    val addedDates: Set<String>,
    val removedDates: Set<String>,
) {
    val affectedDates: Set<String> = addedDates + removedDates
}

private val NO_CATALOG_CHANGES = PhotoCatalogChanges(emptySet(), emptySet())

/**
 * Compares authoritative camera snapshots without treating metadata updates or a surviving
 * dual-card alias as a new/deleted photo. Initial-scan animation policy belongs to the caller:
 * an empty, already-scanned camera must still animate its first newly captured photo.
 */
internal fun publishedCameraChanges(
    previous: List<NikonCamera.FileInfo>,
    current: List<NikonCamera.FileInfo>,
): PhotoCatalogChanges {
    if (previous === current) return NO_CATALOG_CHANGES

    // One handle difference pass covers both directions. Unchanged handles need no logical
    // identity allocation, even if their metadata or storage membership has been refreshed.
    val missingByHandle = previous.associateByTo(HashMap(previous.size)) { it.handle }
    val added = ArrayList<NikonCamera.FileInfo>()
    current.forEach { file ->
        if (missingByHandle.remove(file.handle) == null) added += file
    }
    if (added.isEmpty() && missingByHandle.isEmpty()) return NO_CATALOG_CHANGES

    // Construct an identity index only for a direction that actually has changed handles.
    // A backup-card alias can coexist with, replace, or disappear beside the same logical photo.
    val previousIdentities = if (added.isEmpty()) emptySet() else previous.asSequence()
        .mapTo(HashSet(previous.size)) { it.publishedIdentity() }
    val currentIdentities = if (missingByHandle.isEmpty()) emptySet() else current.asSequence()
        .mapTo(HashSet(current.size)) { it.publishedIdentity() }

    val addedDates = added.asSequence()
        .filter { it.publishedIdentity() !in previousIdentities }
        .mapTo(LinkedHashSet()) { it.captureDate?.take(8) ?: UNKNOWN_DATE_KEY }
    val removedDates = missingByHandle.values.asSequence()
        .filter { it.publishedIdentity() !in currentIdentities }
        .mapTo(LinkedHashSet()) { it.captureDate?.take(8) ?: UNKNOWN_DATE_KEY }
    return if (addedDates.isEmpty() && removedDates.isEmpty()) NO_CATALOG_CHANGES
    else PhotoCatalogChanges(addedDates, removedDates)
}
