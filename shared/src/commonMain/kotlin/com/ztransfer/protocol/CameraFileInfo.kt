package com.ztransfer.protocol

import com.ztransfer.catalog.CameraCatalogFile
import com.ztransfer.catalog.cameraFileExtension

/** Platform-neutral identity and metadata for one camera object exposed as a file. */
data class CameraFileInfo(
    override val handle: Int,
    val size: Long,
    override val fileName: String,
    /** Full PTP DateTime text; grouping consumes its first eight date digits. */
    override val captureDate: String?,
    /** Camera-side protection flag from ObjectInfo ProtectionStatus. */
    override val isProtected: Boolean = false,
    /** One logical file can belong to both storage slots after backup-mode de-duplication. */
    override val storageIds: Set<Int> = emptySet(),
) : CameraCatalogFile {
    /** Lower-case extension with a leading dot, or an empty string when no extension exists. */
    override val extension: String = cameraFileExtension(fileName)
}
