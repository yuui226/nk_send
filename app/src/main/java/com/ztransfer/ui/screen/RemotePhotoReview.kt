package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.core.view.WindowCompat
import com.ztransfer.R
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.labEndLiveView
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.RemoteReviewCatalog
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal class PhotoReviewOptions(
    val loadPreview: suspend (NikonCamera.FileInfo, (ByteArray) -> Unit) -> ImageBitmap?,
    val loadMore: () -> Unit = {},
    val loadingMore: Boolean = false,
    val loadMoreFailed: Boolean = false,
    val landscape: Boolean = false,
)

@Composable
internal fun BoxScope.RemoteReviewCloseButton(landscape: Boolean, onClick: () -> Unit) {
    // Portrait: 6dp header inset + (40dp row - 36dp button) / 2.
    // Landscape: the monitor's control rail starts 8dp from top and ends 4dp from right.
    GlassCloseButton(onClick, Modifier.align(Alignment.TopEnd)
        .padding(top = 8.dp, end = if (landscape) 4.dp else 12.dp))
}

/** Full-screen backdrop; only content avoids system bars, mapped into the monitor's rotation. */
@Composable
internal fun RemoteReviewSurface(rotation: Int, content: @Composable BoxScope.() -> Unit) {
    val density = LocalDensity.current
    val safe = WindowInsets.safeDrawing
    val left = with(density) { safe.getLeft(this, LayoutDirection.Ltr).toDp() }
    val top = with(density) { safe.getTop(this).toDp() }
    val right = with(density) { safe.getRight(this, LayoutDirection.Ltr).toDp() }
    val bottom = with(density) { safe.getBottom(this).toDp() }
    val padding = when (rotation) {
        1 -> PaddingValues.Absolute(left = top, top = right, right = bottom, bottom = left)
        2 -> PaddingValues.Absolute(left = bottom, top = left, right = top, bottom = right)
        else -> PaddingValues.Absolute(left, top, right, bottom)
    }
    val view = LocalView.current
    DisposableEffect(view) {
        val window = view.context.findActivity()?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, view) }
        val lightStatus = controller?.isAppearanceLightStatusBars
        val lightNavigation = controller?.isAppearanceLightNavigationBars
        controller?.isAppearanceLightStatusBars = false
        controller?.isAppearanceLightNavigationBars = false
        onDispose {
            lightStatus?.let { controller?.isAppearanceLightStatusBars = it }
            lightNavigation?.let { controller?.isAppearanceLightNavigationBars = it }
        }
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        // Block monitor controls underneath, including the cutout/navigation margins.
        Box(Modifier.fillMaxSize().clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = {},
        ))
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(safe), content = content)
    }
}

/** One captured state object keeps the monitor's already large Compose method small. */
@Stable
internal class RemotePhotoReviewState {
    val frames = RemoteReviewFrameGate()
    var camera by mutableStateOf<NikonCamera?>(null)
        private set
    val active get() = camera != null
    private val modeChange = Mutex()
    private var restartRequired = false
    var generation = 0L
        private set

    fun open(camera: NikonCamera) {
        if (active) return
        frames.pause()
        generation++
        this.camera = camera
    }

    suspend fun stopLiveViewForCompatibility(expected: NikonCamera): Boolean = modeChange.withLock {
        if (camera !== expected || restartRequired) return@withLock false
        // Even a failed/ambiguous EndLiveView needs a fresh LV session on close.
        restartRequired = true
        withContext(NonCancellable) { runCatching { expected.labEndLiveView() } }
        true
    }

    suspend fun close(expectedGeneration: Long, resumeLiveView: (NikonCamera) -> Unit) = modeChange.withLock {
        if (generation != expectedGeneration) return@withLock
        val previous = camera
        if (restartRequired && previous != null) resumeLiveView(previous)
        restartRequired = false
        camera = null
        frames.resume()
    }

    fun dispose() { camera = null; frames.resume() }
}

@Composable
internal fun RemoteReviewButton(enabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val label = stringResource(R.string.remote_review)
    val color = AppTheme.colors.onBackground.copy(alpha = if (enabled) 0.9f else 0.35f)
    GlassButton(onClick = onClick, enabled = enabled,
        modifier = modifier.size(width = 40.dp, height = 48.dp).semantics { contentDescription = label },
        shape = RoundedCornerShape(12.dp), contentPadding = PaddingValues(0.dp)) {
        Canvas(Modifier.size(width = 19.dp, height = 26.dp)) {
            val stroke = 1.5.dp.toPx()
            drawRoundRect(color, Offset(stroke / 2, stroke / 2),
                Size(size.width - stroke, size.height - stroke), CornerRadius(3.dp.toPx()), style = Stroke(stroke))
            drawCircle(color, 1.6.dp.toPx(), Offset(size.width * .68f, size.height * .28f))
            drawPath(Path().apply {
                moveTo(size.width * .17f, size.height * .72f)
                lineTo(size.width * .40f, size.height * .48f)
                lineTo(size.width * .59f, size.height * .64f)
                lineTo(size.width * .72f, size.height * .55f)
                lineTo(size.width * .84f, size.height * .72f)
            }, color, style = Stroke(stroke))
        }
    }
}

@Composable
internal fun RemotePhotoReview(
    state: RemotePhotoReviewState,
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    rotation: Int,
    onClose: () -> Unit,
) {
    val camera = state.camera ?: return
    key(camera) {
        val scope = rememberCoroutineScope()
        val transfer by transferViewModel.state.collectAsState()
        var catalog by remember { mutableStateOf<RemoteReviewCatalog?>(null) }
        var items by remember { mutableStateOf<List<PhotoPreviewItem>>(emptyList()) }
        var loading by remember { mutableStateOf(true) }
        var failed by remember { mutableStateOf(false) }
        var retry by remember { mutableIntStateOf(0) }
        fun stillCurrent() = state.camera === camera && cameraViewModel.getCamera() === camera

        suspend fun loadFirst() {
            loading = true
            failed = false
            try {
                state.frames.awaitIdle()
                // Let the camera finish registering the just-created object before enumerating it.
                delay(200)
                suspend fun read() {
                    val snapshot = cameraViewModel.openRemoteReviewCatalog(camera)
                    val files = snapshot.loadNextPage()
                    if (!stillCurrent()) return
                    catalog = snapshot
                    items = files.map { PhotoPreviewItem.Photo(it) }
                }
                try { read() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) {
                    if (!stillCurrent() || !state.stopLiveViewForCompatibility(camera)) throw error
                    delay(200)
                    read()
                }
                // Some bodies acknowledge enumeration while LV is active but expose no objects.
                if (items.isEmpty() && stillCurrent() && state.stopLiveViewForCompatibility(camera)) {
                    delay(200)
                    read()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
            finally { loading = false }
        }

        val loadMore: () -> Unit = {
            val snapshot = catalog
            if (!loading && snapshot != null && snapshot.hasMore && stillCurrent()) {
                loading = true
                failed = false
                scope.launch {
                    try {
                        val files = snapshot.loadNextPage()
                        if (stillCurrent()) items = files.map { PhotoPreviewItem.Photo(it) }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { failed = true }
                    finally { loading = false }
                }
            }
        }
        LaunchedEffect(retry) { loadFirst() }

        RemoteReviewSurface(rotation) {
            if (items.isNotEmpty()) {
                PhotoPreviewOverlay(
                    items = items, initialIndex = 0, anchorRect = null,
                    cameraViewModel = cameraViewModel,
                    hapticsEnabled = transfer.hapticsEnabled, transfersBusy = transfer.isTransferring,
                    activeProgressFlow = transferViewModel.activeTransferProgress,
                    initialRotationQuarterTurns = transfer.previewRotationQuarterTurns,
                    histogramMode = transfer.previewHistogramMode,
                    onRotationChanged = transferViewModel::setPreviewRotationQuarterTurns,
                    onHistogramModeChanged = transferViewModel::setPreviewHistogramMode,
                    review = PhotoReviewOptions(
                        loadPreview = { file, onJpeg ->
                            if (!stillCurrent()) throw CancellationException("Review camera changed")
                            var image = cameraViewModel.loadFhdPreview(file, onJpeg)
                            if (image == null && stillCurrent() && state.stopLiveViewForCompatibility(camera)) {
                                delay(200)
                                if (stillCurrent()) image = cameraViewModel.loadFhdPreview(file, onJpeg)
                            }
                            image
                        },
                        loadMore = loadMore, loadingMore = loading, loadMoreFailed = failed,
                        landscape = rotation != 0,
                    ),
                    onDismiss = { onClose() },
                )
            } else {
                BackHandler { onClose() }
                RemoteReviewCloseButton(landscape = rotation != 0, onClick = onClose)
                if (loading) CircularProgressIndicator(Modifier.align(Alignment.Center).size(28.dp),
                    color = Color.White, strokeWidth = 2.dp)
                else if (failed) TextButton(onClick = { retry++ }, modifier = Modifier.align(Alignment.Center)) {
                    Text(stringResource(R.string.remote_review_retry), color = Color.White)
                } else Text(stringResource(R.string.remote_review_empty),
                    modifier = Modifier.align(Alignment.Center), color = Color.White)
            }
        }
    }
}
