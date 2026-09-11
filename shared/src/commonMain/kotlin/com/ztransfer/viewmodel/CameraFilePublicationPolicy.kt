package com.ztransfer.viewmodel

import com.ztransfer.catalog.cameraFileLogicalIdentity
import com.ztransfer.catalog.mergeStorageIds
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants

val effectPreviewVideoExtensions = setOf(".mov", ".mp4")
private val autoTransferMediaExtensions = PtpConstants.FORMAT_EXT.values.toSet()

/** Unknown PTP objects remain visible, but only known photo/video formats are auto-transferred. */
fun isAutoTransferMedia(file: CameraFileInfo): Boolean =
    file.extension in autoTransferMediaExtensions

/** Selects the newest still deterministically; video covers never become effect previews. */
fun latestEffectPreviewFile(files: List<CameraFileInfo>): CameraFileInfo? =
    files.asSequence()
        .filter { it.extension !in effectPreviewVideoExtensions }
        .maxWithOrNull(compareBy<CameraFileInfo>({ it.captureDate.orEmpty() }, { it.handle }))

/** Stable across sessions so reconnecting to the same file reuses its EXIF cache entry. */
fun exifKey(file: CameraFileInfo): String =
    "${file.fileName}_${file.size}_${file.captureDate ?: "0"}"

/** Includes the session handle because preview loading is scoped to the current camera catalog. */
fun effectPreviewKey(file: CameraFileInfo): String =
    "${file.handle}|${file.fileName}|${file.size}|${file.captureDate.orEmpty()}"

fun CameraFileInfo.logicalIdentity(): String =
    cameraFileLogicalIdentity(fileName, size, captureDate)

/** Keeps one visible backup row while retaining its complete storage-card membership. */
fun mergeStorageMembership(
    existing: CameraFileInfo,
    duplicate: CameraFileInfo,
): CameraFileInfo {
    val mergedStorageIds = mergeStorageIds(existing.storageIds, duplicate.storageIds)
    if (mergedStorageIds === existing.storageIds) return existing
    return existing.copy(storageIds = mergedStorageIds)
}

/**
 * Rebuilds already-published rows after a handle catalog shrinks. A surviving backup alias replaces
 * a removed primary without changing logical display order.
 */
fun reconcilePublishedCameraFiles(
    publishedFiles: List<CameraFileInfo>,
    currentHandles: Set<Int>,
    indexedFilesByHandle: Map<Int, CameraFileInfo>,
): List<CameraFileInfo> {
    val aliasesByIdentity = LinkedHashMap<String, MutableList<CameraFileInfo>>()
    indexedFilesByHandle.forEach { (handle, file) ->
        if (handle in currentHandles) {
            aliasesByIdentity.getOrPut(file.logicalIdentity()) { ArrayList(1) } += file
        }
    }
    return publishedFiles.mapNotNull { published ->
        val aliases = aliasesByIdentity[published.logicalIdentity()]
        if (aliases.isNullOrEmpty()) {
            published.takeIf { it.handle in currentHandles }
        } else {
            val primary = aliases.firstOrNull { it.handle == published.handle } ?: aliases.first()
            aliases.asSequence()
                .filterNot { it.handle == primary.handle }
                .fold(primary, ::mergeStorageMembership)
        }
    }
}
