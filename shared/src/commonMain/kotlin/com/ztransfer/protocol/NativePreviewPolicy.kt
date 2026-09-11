package com.ztransfer.protocol

import com.ztransfer.catalog.thumbnailCacheKeyMaterial
import com.ztransfer.catalog.cameraThumbnailCacheIdentity
import com.ztransfer.catalog.normalizedCameraIdentifier
import com.ztransfer.catalog.isThumbnailCameraCacheExpired

/** Scalar Apple bridge for existing AP preview capability rules. Owned by one camera actor. */
class NativePreviewPolicy {
    private var supported: Boolean? = null
    val disabled: Boolean get() = supported == false
    val busyRetries: Int get() = 2 // NikonCamera.FHD_DEVICE_BUSY_RETRIES
    val busyDelayMs: Long get() = 160L // NikonCamera.FHD_DEVICE_BUSY_RETRY_DELAY_MS
    fun record(response: Int, hasPayload: Boolean): Boolean {
        val disposition = classifyFhdResponse(response, hasPayload)
        supported = updateFhdSupport(supported, disposition)
        return disposition == FhdResponseDisposition.SUCCESS
    }
    fun thumbnailKey(info: PtpObjectInfo): String = thumbnailCacheKeyMaterial(
        info.fileName.orEmpty(), info.size, info.captureDate)
    fun isVideo(file: CameraFileInfo): Boolean = file.extension in com.ztransfer.viewmodel.effectPreviewVideoExtensions
    fun rememberThumbnailMiss(direct: Boolean, info: PtpObjectInfo): Boolean =
        com.ztransfer.catalog.shouldRememberThumbnailMiss(direct, com.ztransfer.catalog.cameraFileExtension(info.fileName.orEmpty()))
    fun prefetchThumbnail(direct: Boolean, file: CameraFileInfo): Boolean =
        com.ztransfer.catalog.shouldPrefetchThumbnailInBackground(direct, file.extension)
    /** Native allocation admission only; never resize an original silently or alter Android decode. */
    fun originalPixelsAllowed(width: Int, height: Int): Boolean =
        width > 0 && height > 0 && width.toLong() * height <= 96L * 1024 * 1024
    fun thumbnailPixelsAllowed(width: Int, height: Int): Boolean =
        width > 0 && height > 0 && width.toLong() * height <= 32L * 1024 * 1024

    fun cameraKey(info: LabDeviceInfo?, responderGuid: String?, sessionId: String): String = cameraThumbnailCacheIdentity(
        info?.manufacturer, info?.model, info?.serial,
        normalizedCameraIdentifier(responderGuid) ?: "session:$sessionId",
    ) // Unknown cameras remain isolated per connection; never persist under a shared unknown-device bucket.

    fun cameraCacheExpired(lastConnectedMs: Long, nowMs: Long): Boolean =
        isThumbnailCameraCacheExpired(lastConnectedMs, nowMs)

    /** Queue rows already have validated identities; unknown objectFormat is unused by GetThumb. */
    fun originalThumbnailInfo(file: CameraFileInfo): PtpObjectInfo = PtpObjectInfo(
        file.handle, file.storageIds.firstOrNull() ?: 0, 0, file.size,
        file.fileName, file.captureDate, file.isProtected, false, true,
    )
}

/** Paired-computer preview differs from standard AP: AccessDenied also disables that operation. */
class NativeStaPreviewPolicy {
    private val support = mutableMapOf<Int, Boolean>()
    fun shouldRequest(operation: Int, advertised: Boolean): Boolean =
        support[operation] != false && (operation != PtpConstants.NK_GET_LARGE_THUMB || advertised)
    fun record(operation: Int, response: Int, validJpeg: Boolean) {
        if (validJpeg) support[operation] = true
        else if (response == PtpConstants.OPERATION_NOT_SUPPORTED || response == 0x200F) support[operation] = false
    }
    fun rawCandidates(values: List<com.ztransfer.preview.NefPreviewReference>): List<com.ztransfer.preview.NefPreviewReference> {
        val ordered = values.distinct().sortedBy { it.length }
        return ordered.filter { it.length >= 512 * 1024 }.ifEmpty { ordered }
    }
    fun rawPreviewAdequate(width: Int, height: Int): Boolean = maxOf(width, height) >= 1600
}
