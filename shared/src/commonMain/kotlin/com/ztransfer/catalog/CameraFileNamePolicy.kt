package com.ztransfer.catalog

/** Normalized extension used by camera-file filtering and burst grouping. */
fun cameraFileExtension(fileName: String): String = fileName.lastIndexOf('.').let { dot ->
    if (dot < 0) "" else fileName.substring(dot).lowercase()
}
