package com.ztransfer.protocol

import java.util.Locale

private val jpegExtensions = setOf(".jpg", ".jpeg")

/** A unique same-name JPEG supplies its paired NEF's rating; ambiguous matches stay independent. */
internal fun photoRatingSources(files: List<NikonCamera.FileInfo>): Map<Int, NikonCamera.FileInfo> {
    fun stem(file: NikonCamera.FileInfo) = file.fileName.substringBeforeLast('.').lowercase(Locale.ROOT)
    val jpegs = files.filter { it.extension in jpegExtensions }.groupBy(::stem)
    return files.associate { file ->
        val paired = if (file.extension == ".nef") jpegs[stem(file)].orEmpty().filter { jpeg ->
            (file.storageIds.isEmpty() || jpeg.storageIds.isEmpty() || file.storageIds.any { it in jpeg.storageIds }) &&
                (file.captureDate.isNullOrBlank() || jpeg.captureDate.isNullOrBlank() || file.captureDate == jpeg.captureDate)
        }.singleOrNull() else null
        file.handle to (paired ?: file)
    }
}
