package com.ztransfer.ui

import androidx.compose.runtime.*
import androidx.compose.ui.graphics.ImageBitmap
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.*
import com.ztransfer.viewmodel.PhotoExif
import kotlinx.coroutines.flow.StateFlow
import platform.Foundation.NSProcessInfo

/** One original overlay's platform input. The shared overlay still owns paging, ordering and caches. */
internal class NativePreviewSessionSource(
    private val reads: NativePreviewReadSession,
    grid: NativeGridImages,
    connection: StateFlow<Boolean>,
    files: List<CameraFileInfo>,
    localSources: Map<CameraFileInfo, String>,
) : PreviewSessionSource<String> {
    private var closed by mutableStateOf(false)
    private var connection: StateFlow<Boolean>? = connection
    private val images = grid.preview(reads, files)
    private var filesByHandle = files.associateBy { it.handle }
    private var sources = localSources.filterKeys { filesByHandle[it.handle] == it }.toMap()
    // decodeLocal receives only the frozen source. Recover its opening file identity for the IO bridge.
    private var filesBySource = sources.entries.associate { (file, source) -> source to file }

    @Composable override fun connected(): Boolean = !closed && connection?.collectAsState()?.value == true

    override fun setFhdActive(active: Boolean) {
        // beginPreviewReads already owns foreground-use suppression before the first read.
        // The original overlay calls false only on disposal; this source is never reused/reopened.
        if (!active) close()
    }

    override fun localRoute(extension: String): LocalOriginalPreviewRoute = originalLocalPreviewRoute(extension)

    fun localSource(file: CameraFileInfo): String? = if (closed) null else sources[file]

    override suspend fun decodeLocal(source: String, route: LocalOriginalPreviewRoute): ImageBitmap? {
        val file = filesBySource[source] ?: return null
        if (closed || localRoute(file.extension) != route) return null
        return when (route) {
            LocalOriginalPreviewRoute.DIRECT_BITMAP -> images.local(file, source)
            LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG -> images.localRaw(file, source)
            LocalOriginalPreviewRoute.CAMERA_FHD -> null
        }
    }

    override suspend fun loadFhdPreview(file: CameraFileInfo): ImageBitmap? = images.fhd(file)
    override fun cached(handle: Int): ImageBitmap? = images.cached(handle)
    override suspend fun thumbnail(file: CameraFileInfo, allowRemote: Boolean): ImageBitmap? = images.thumbnail(file, allowRemote)

    override suspend fun loadLocalExif(file: CameraFileInfo, source: String): PhotoExif? =
        if (closed || sources[file] != source) null else reads.localExif(file, source)

    override suspend fun loadExif(file: CameraFileInfo): PhotoExif? =
        if (closed || filesByHandle[file.handle] != file) null else reads.exif(file)

    override suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T =
        reads.withInteractivePriority(block)

    override fun histogram(bitmap: ImageBitmap): LuminanceHistogram = calculateImageLuminanceHistogram(bitmap)
    override fun uptimeMillis(): Long = (NSProcessInfo.processInfo.systemUptime * 1000.0).toLong()

    fun close() {
        if (closed) return
        closed = true
        connection = null; sources = emptyMap(); filesBySource = emptyMap(); filesByHandle = emptyMap()
        images.close() // Ends this read lifetime, not the borrowed grid/queue/camera or EXIF cache.
    }

    companion object {
        /** Must be called on UI when opening, never keyed to later queue/index revisions. */
        fun open(model: NativeFilesPageModel, grid: NativeGridImages, files: List<CameraFileInfo>): NativePreviewSessionSource? {
            val frozenFiles = files.toList()
            val localSources = frozenFiles.mapNotNull { file -> model.localOriginalSource(file)?.let { file to it } }.toMap()
            val reads = model.beginPreviewReads() ?: return null
            return NativePreviewSessionSource(reads, grid, model.queue.connected, frozenFiles, localSources)
        }
    }
}
