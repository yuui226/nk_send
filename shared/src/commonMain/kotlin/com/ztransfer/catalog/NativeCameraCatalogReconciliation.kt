package com.ztransfer.catalog

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpObjectInfo
import com.ztransfer.viewmodel.NewCameraObjectPolicy
import com.ztransfer.viewmodel.reconcilePublishedCameraFiles

/** Narrow Native access to the SAME published-row removal policy already used by Android. */
object NativeCameraCatalogReconciliation {
    /**
     * Pass handles only after all required queries succeeded and the connection is still current.
     * Null is a failed/incomplete query, never a successful empty camera. No IO or baseline mutation.
     * Preserve indexed metadata order: it chooses the surviving alias when the primary disappears.
     */
    fun reconcile(
        publishedFiles: List<CameraFileInfo>,
        currentHandles: IntArray?,
        indexedInfos: List<PtpObjectInfo>,
    ): List<CameraFileInfo>? {
        val current = currentHandles?.toSet() ?: return null
        val indexed = LinkedHashMap<Int, CameraFileInfo>()
        for (info in indexedInfos) {
            val file = NewCameraObjectPolicy.publicationFile(info) ?: continue
            indexed[file.handle] = file
        }
        return reconcilePublishedCameraFiles(publishedFiles, current, indexed)
    }
}
