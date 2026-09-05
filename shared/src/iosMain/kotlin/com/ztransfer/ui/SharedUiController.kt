package com.ztransfer.ui

import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.QueueThumbnailContent
import com.ztransfer.ui.screen.ThumbnailGridImageSource
import com.ztransfer.ui.theme.SharedZTransferTheme
import org.jetbrains.skia.Image
import platform.Foundation.NSProcessInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.posix.memcpy
import com.ztransfer.ui.screen.SharedSinglePhotoPreviewOverlay

/** Thin UIKit host; product pages will reuse the same commonMain components, not SwiftUI copies. */
@OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
object SharedUiController {
    fun componentProbe(): UIViewController = ComposeUIViewController { SharedUiComponentProbe() }

    /** Frozen ImageIO-normalized diagnostic image; the full catalog preview coordinator is separate work. */
    fun singlePhotoPreview(data: NSData, title: String, rotationDescription: String, onBack: () -> Unit): UIViewController? {
        if (data.length < 33uL || data.length > SINGLE_PHOTO_MAX_BYTES.toULong()) return null
        val source = data.bytes ?: return null
        val bytes = ByteArray(data.length.toInt())
        bytes.usePinned { memcpy(it.addressOf(0), source, data.length) } // One bounded copy, not millions of ObjC calls.
        if (!isBoundedSinglePhotoPng(bytes)) return null
        val bitmap = try {
            val image = Image.makeFromEncoded(bytes)
            try { image.toComposeImageBitmap() } finally { image.close() }
        } catch (_: Exception) { return null }
        return ComposeUIViewController {
            SharedZTransferTheme {
                SharedSinglePhotoPreviewOverlay(bitmap, title, anchorRect = null, onDismiss = onBack,
                    backHandler = { _, _ -> }, // No Android hardware Back; original tap-close remains active.
                    rotationDescription = { rotationDescription })
            }
        }
    }

    fun originalFiles(model: NativeFilesPageModel, languageTag: String, onBack: () -> Unit): UIViewController =
        ComposeUIViewController {
            val images = remember(model) { NativeGridImages(model) }
            DisposableEffect(images) { onDispose { images.clear() } }
            SharedZTransferTheme {
                val queueText = NativeQueueTextCatalog.forLanguage(languageTag)
                NativeOriginalFilesPage(model, NativeFilesTextCatalog.forLanguage(languageTag), queueText,
                    NativeFilterTextCatalog.forLanguage(languageTag), images, onBack,
                    queuePage = { back ->
                        NativeOriginalQueuePage(model.queue, queueText,
                            elapsedRealtimeMs = { (NSProcessInfo.processInfo.systemUptime * 1000.0).toLong() },
                            onBack = back,
                            thumbnail = { file, nudge, modifier -> OriginalQueueThumbnail(model.queue, file, nudge, modifier) })
                    })
            }
        }

    fun originalQueue(model: NativeQueuePageModel, languageTag: String, onBack: () -> Unit): UIViewController =
        ComposeUIViewController {
            SharedZTransferTheme {
                NativeOriginalQueuePage(model, NativeQueueTextCatalog.forLanguage(languageTag),
                    elapsedRealtimeMs = { (NSProcessInfo.processInfo.systemUptime * 1000.0).toLong() },
                    onBack = onBack,
                    thumbnail = { file, retryNudge, modifier -> OriginalQueueThumbnail(model, file, retryNudge, modifier) })
            }
        }
}

/** Decoded UI cache is page-bound; the connection's encoded cache remains in CameraPreviewStore. */
private class NativeGridImages(private val model: NativeFilesPageModel) : ThumbnailGridImageSource {
    private val cache = LinkedHashMap<CameraFileInfo, ImageBitmap>()
    private var bytes = 0L
    fun clear() { cache.clear(); bytes = 0L }
    private fun cached(file: CameraFileInfo): ImageBitmap? = cache.remove(file)?.also { cache[file] = it }
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
        var bitmap by remember(file) { mutableStateOf(cached(file)) }
        LaunchedEffect(file, busy, enabled, remote) {
            if (enabled && remote && bitmap == null) {
                repeat(8) { attempt ->
                    try {
                        val result = model.thumbnail(file)
                        result.bytes?.let { encoded ->
                            val image = Image.makeFromEncoded(encoded)
                            try { bitmap = image.toComposeImageBitmap() } finally { image.close() }
                            bitmap?.let { store(file, it) }
                        }
                        if (bitmap != null || !result.retryable) return@LaunchedEffect
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { return@LaunchedEffect }
                    delay((250L * (attempt + 1)).coerceAtMost(2000L))
                }
            }
        }
        return bitmap
    }
}

@Composable
private fun OriginalQueueThumbnail(model: NativeQueuePageModel, file: CameraFileInfo, retryNudge: Boolean, modifier: Modifier) {
    val connected by model.connected.collectAsState()
    var bitmap by remember(model, file.handle) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(model, file.handle, retryNudge, connected) {
        if (connected && bitmap == null) {
            try {
                model.thumbnail(file)?.let { encoded ->
                    val image = Image.makeFromEncoded(encoded)
                    try { bitmap = image.toComposeImageBitmap() } finally { image.close() }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* Keep the original placeholder; retry on the next queue boundary. */ }
        }
    }
    QueueThumbnailContent(bitmap, modifier)
}
