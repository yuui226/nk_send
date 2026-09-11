package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo

/** Original CameraViewModel new-object decisions. Platform owners keep IO, clocks and scheduling. */
object NewCameraObjectPolicy {
    fun publicationFile(info: com.ztransfer.protocol.PtpObjectInfo): CameraFileInfo? {
        if (info.isAssociation) return null
        val name = info.fileName ?: return null
        return CameraFileInfo(info.handle, info.size, name, info.captureDate, info.isProtected,
            if (info.storageId == 0 || info.storageId == -1) emptySet() else setOf(info.storageId))
    }
    fun automaticMedia(file: CameraFileInfo): Boolean = isAutoTransferMedia(file)
    const val COALESCE_MS = 90L
    const val RESOLVE_BATCH_SIZE = 16
    const val RESOLVE_MAX_ATTEMPTS = 5
    private val backoffMs = longArrayOf(180L, 360L, 720L, 1_400L)

    /** Called only after a failed attempt below RESOLVE_MAX_ATTEMPTS, as on Android. */
    fun retryDelayMs(attempts: Int): Long = backoffMs[attempts - 1]

    /** Null means no successful baseline yet, not an authoritative empty camera. */
    fun shouldResolve(handle: Int, knownHandles: Set<Int>?, visibleFiles: List<CameraFileInfo>): Boolean {
        if (handle == 0 || handle == -1) return false
        if (knownHandles != null && handle in knownHandles) return false
        return visibleFiles.none { it.handle == handle }
    }

    fun isNew(files: List<CameraFileInfo>, handle: Int, info: CameraFileInfo): Boolean =
        files.none { it.handle == handle || it.logicalIdentity() == info.logicalIdentity() }

    /** Prepend a genuinely new row; a backup alias only expands the first matching row's stores. */
    fun publish(files: List<CameraFileInfo>, handle: Int, info: CameraFileInfo): List<CameraFileInfo> {
        val duplicateIndex = files.indexOfFirst {
            it.handle == handle || it.logicalIdentity() == info.logicalIdentity()
        }
        if (duplicateIndex < 0) return listOf(info) + files
        val existing = files[duplicateIndex]
        val merged = mergeStorageMembership(existing, info)
        return if (merged === existing) files else files.toMutableList().apply { this[duplicateIndex] = merged }
    }
}
