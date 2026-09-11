package com.ztransfer.ui

import androidx.compose.runtime.*
import androidx.compose.ui.graphics.ImageBitmap
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.ThumbnailGridImageSource
import kotlinx.coroutines.*

/** Decoded UI cache is page-bound; the connection's encoded cache remains in CameraPreviewStore. */
internal class NativeGridImages(private val model: NativeFilesPageModel) : ThumbnailGridImageSource {
    private val cache = LinkedHashMap<CameraFileInfo, ImageBitmap>()
    private var bytes = 0L
    private var closed = false
    private var memoryEpoch by mutableLongStateOf(0L)
    fun releaseMemory() { memoryEpoch++; cache.clear(); bytes = 0L }
    fun close() { closed = true; releaseMemory() }
    fun preview(reads: NativePreviewReadSession, files: List<CameraFileInfo>) = NativePreviewBitmaps(reads, this, files)
    fun cached(file: CameraFileInfo): ImageBitmap? =
        if (closed) null else cache.remove(file)?.also { cache[file] = it }
    suspend fun thumbnail(file: CameraFileInfo, allowRemote: Boolean): ImageBitmap? =
        cached(file) ?: load(file, allowRemote).bitmap
    private data class Loaded(val bitmap: ImageBitmap?, val retryable: Boolean)
    private suspend fun load(file: CameraFileInfo, allowRemote: Boolean): Loaded {
        if (closed) return Loaded(null, false)
        val epoch = memoryEpoch
        val result = model.thumbnail(file, allowRemote)
        val bitmap = result.bytes?.let { encoded ->
            withContext(Dispatchers.Default) { decodeNativePreviewBitmap(encoded, maxEdge = 512) }
        }
        currentCoroutineContext().ensureActive()
        if (closed || epoch != memoryEpoch) return Loaded(null, false)
        bitmap?.let { store(file, it) }
        return Loaded(bitmap, result.retryable)
    }
    private fun store(file: CameraFileInfo, image: ImageBitmap) {
        val cost = image.width.toLong() * image.height * 4L
        if (cost > 32L * 1024 * 1024) return
        cache.remove(file)?.let { bytes -= it.width.toLong() * it.height * 4L }
        while (cache.isNotEmpty() && (cache.size >= 128 || bytes + cost > 32L * 1024 * 1024)) {
            val first = cache.entries.first()
            bytes -= first.value.width.toLong() * first.value.height * 4L
            cache.remove(first.key)
        }
        cache[file] = image; bytes += cost
    }
    @Composable override fun photo(file: CameraFileInfo, transfersBusy: Boolean, allowRemoteThumbnail: Boolean): ImageBitmap? =
        image(file, transfersBusy, true, allowRemoteThumbnail)
    @Composable override fun stack(file: CameraFileInfo, transfersBusy: Boolean, loadEnabled: Boolean, allowRemoteThumbnail: Boolean): ImageBitmap? =
        image(file, transfersBusy, loadEnabled, allowRemoteThumbnail)
    @Composable private fun image(file: CameraFileInfo, busy: Boolean, enabled: Boolean, remote: Boolean): ImageBitmap? {
        var bitmap by remember(file, memoryEpoch) { mutableStateOf(cached(file)) }
        LaunchedEffect(file, busy, enabled, remote, memoryEpoch) {
            if (enabled && bitmap == null) {
                repeat(8) { attempt ->
                    try {
                        val result = load(file, remote)
                        bitmap = result.bitmap
                        if (bitmap != null || !result.retryable || !remote) return@LaunchedEffect
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { return@LaunchedEffect }
                    delay((250L * (attempt + 1)).coerceAtMost(2000L))
                }
            }
        }
        return bitmap
    }
}
