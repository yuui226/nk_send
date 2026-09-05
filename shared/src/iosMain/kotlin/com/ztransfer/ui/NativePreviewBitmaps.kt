package com.ztransfer.ui

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.PreviewPageImages
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.jetbrains.skia.Image

/** Decode once, close the temporary Skia Image, then hand the independent bitmap to the shared UI. */
internal fun decodeNativePreviewBitmap(
    encoded: ByteArray, expectedWidth: Int? = null, expectedHeight: Int? = null, maxEdge: Int = Int.MAX_VALUE,
): ImageBitmap? = try {
    val image = Image.makeFromEncoded(encoded)
    try {
        if (image.width !in 1..maxEdge || image.height !in 1..maxEdge ||
            (expectedWidth != null && image.width != expectedWidth) ||
            (expectedHeight != null && image.height != expectedHeight)) null
        else image.toComposeImageBitmap()
    } finally { image.close() }
} catch (cancelled: CancellationException) { throw cancelled }
catch (_: Exception) { null }

/** One overlay borrows the grid's decoded thumbnails. FHD/local caches stay in the shared overlay. */
internal class NativePreviewBitmaps(
    private val reads: NativePreviewReadSession,
    grid: NativeGridImages,
    files: List<CameraFileInfo>,
) : PreviewPageImages {
    private var owner: NativeGridImages? = grid
    private var filesByHandle = files.associateBy { it.handle }
    private fun current(file: CameraFileInfo) = owner != null && filesByHandle[file.handle] == file

    override fun cached(handle: Int): ImageBitmap? = filesByHandle[handle]?.let { owner?.cached(it) }

    override suspend fun thumbnail(file: CameraFileInfo, allowRemote: Boolean): ImageBitmap? {
        if (!current(file)) return null
        val bitmap = owner?.thumbnail(file, allowRemote)
        return bitmap.takeIf { current(file) }
    }

    suspend fun fhd(file: CameraFileInfo): ImageBitmap? {
        if (!current(file)) return null
        val image = reads.fhd(file) ?: return null
        val bitmap = withContext(Dispatchers.Default) {
            decodeNativePreviewBitmap(image.encoded, image.width, image.height, 1920)
        }
        return bitmap.takeIf { current(file) }
    }

    suspend fun local(file: CameraFileInfo, source: String): ImageBitmap? {
        if (!current(file)) return null
        val image = reads.localBitmap(file, source) ?: return null
        val bitmap = withContext(Dispatchers.Default) {
            decodeNativePreviewBitmap(image.encoded, image.width, image.height)
        }
        return bitmap.takeIf { current(file) }
    }

    suspend fun localRaw(file: CameraFileInfo, source: String): ImageBitmap? {
        if (!current(file)) return null
        val image = reads.localRaw(file, source) ?: return null
        val bitmap = withContext(Dispatchers.Default) {
            decodeNativePreviewBitmap(image.encoded, image.width, image.height)
        }
        return bitmap.takeIf { current(file) }
    }

    fun close() {
        owner = null; filesByHandle = emptyMap()
        reads.close() // Never clear the parent grid cache or close its queue/camera.
    }
}
