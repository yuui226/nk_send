package com.ztransfer.catalog

/**
 * Small read-only view of the camera file facts used by shared catalog policies.
 *
 * Platform catalog models implement this directly so sorting and filtering return the original
 * objects without projections, copies, or handle lookups.
 */
interface CameraCatalogFile {
    val handle: Int
    val fileName: String
    val captureDate: String?
    val isProtected: Boolean
    val storageIds: Set<Int>
    val extension: String
}
