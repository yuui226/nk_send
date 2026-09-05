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
