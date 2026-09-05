"""Extract the COMPLETE original preview coordinator using enumerated platform boundaries."""
from thumbnail_grid_extraction import section
from transfer_card_extraction import replace_once
from photo_preview_display_extraction import wrapper
from preview_async_enqueue_wiring import add_async_preview_enqueue

HEADER = '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

'''

CONTRACT = HEADER + '''import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.ImageBitmap
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.PhotoExif

/** IO only. The original shared overlay owns snapshots, page jobs, priority order and eviction. */
@kotlin.native.HiddenFromObjC
interface PreviewSessionSource<Source : Any> : PreviewPageImages {
    @Composable fun connected(): Boolean
    fun setFhdActive(active: Boolean)
    fun localRoute(extension: String): LocalOriginalPreviewRoute
    suspend fun decodeLocal(source: Source, route: LocalOriginalPreviewRoute): ImageBitmap?
    suspend fun loadFhdPreview(file: CameraFileInfo): ImageBitmap?
    suspend fun loadLocalExif(file: CameraFileInfo, source: Source): PhotoExif?
    suspend fun loadExif(file: CameraFileInfo): PhotoExif?
    suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T
    fun histogram(bitmap: ImageBitmap): LuminanceHistogram
    fun uptimeMillis(): Long
}

@kotlin.native.HiddenFromObjC
interface PreviewSessionText : PreviewPageText {
    @Composable fun burstLabel(): String
    @Composable fun protectedLabel(): String
    @Composable fun histogramDescription(): String
    @Composable fun rotationDescription(): String
}
'''

WRAPPER_CALL = '''val contentResolver = LocalContext.current.contentResolver
    val session = remember(cameraViewModel, contentResolver) { AndroidPreviewSession(cameraViewModel, contentResolver) }
    SharedPhotoPreviewOverlay(
        items = items, initialIndex = initialIndex, anchorRect = anchorRect, session = session,
        text = AndroidPreviewPageText,
        burstContent = remember(cameraViewModel) { AndroidPreviewBurstContent(cameraViewModel) },
        backHandler = { enabled, onBack -> BackHandler(enabled, onBack) },
        hapticsEnabled = hapticsEnabled, transfersBusy = transfersBusy,
        initialRotationQuarterTurns = initialRotationQuarterTurns, histogramVisible = histogramVisible,
        burstHandles = burstHandles, queueTaskFor = queueTaskFor, isTransferred = isTransferred,
        localOriginalUriFor = localOriginalUriFor,
        activeProgress = { activeProgressFlow.collectAsStateWithLifecycle().value },
        queueTargetBounds = queueTargetBounds, onQueueFlightCaught = onQueueFlightCaught,
        onTransfer = onTransfer, onTransferBurst = onTransferBurst,
        onBurstExpandedChange = onBurstExpandedChange, onRotationChanged = onRotationChanged,
        onHistogramVisibleChanged = onHistogramVisibleChanged,
        prepareDismissTarget = prepareDismissTarget, onDismiss = onDismiss,
    )'''

ANDROID_SESSION_METHODS = '''    @Composable override fun connected(): Boolean {
        val cameraState by cameraViewModel.state.collectAsState()
        return cameraState.isConnectedToCamera
    }
    override fun setFhdActive(active: Boolean) = cameraViewModel.setFhdActive(active)
    override fun localRoute(extension: String): LocalOriginalPreviewRoute = localOriginalPreviewRoute(extension)
    override suspend fun decodeLocal(source: Uri, route: LocalOriginalPreviewRoute): ImageBitmap? =
        withContext(Dispatchers.IO) {
            val bitmap = when (route) {
                LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG -> PhotoFrameExporter.decodeRawEmbeddedPreview(contentResolver, source)
                LocalOriginalPreviewRoute.DIRECT_BITMAP -> PhotoFrameExporter.decodeOriginalPreview(contentResolver, source)
                LocalOriginalPreviewRoute.CAMERA_FHD -> null
            }
            bitmap?.asImageBitmap()
        }
    override suspend fun loadFhdPreview(file: CameraFileInfo): ImageBitmap? = cameraViewModel.loadFhdPreview(file)
    override suspend fun loadLocalExif(file: CameraFileInfo, source: Uri): PhotoExif? = cameraViewModel.loadLocalExif(file, source)
    override suspend fun loadExif(file: CameraFileInfo): PhotoExif? = cameraViewModel.loadExif(file)
    override suspend fun <T> withInteractivePreviewPriority(block: suspend () -> T): T =
        cameraViewModel.withInteractivePreviewPriority(block)
    override fun histogram(bitmap: ImageBitmap): LuminanceHistogram = calculateLuminanceHistogram(bitmap.asAndroidBitmap())
    override fun uptimeMillis(): Long = SystemClock.uptimeMillis()
'''


def counted(source, old, new, count):
    if source.count(old) != count:
        raise ValueError(f'Expected {count} occurrences: {old!r}, got {source.count(old)}')
    return source.replace(old, new)


def extract_queue_flight(source):
    source = source.replace('\r\n', '\n')
    body = section(source, 'internal val QueueFlightEasing', '/**\n * "打包 → 吸入"两幕连播:')
    android = replace_once(source, body, '')
    shared = HEADER + '''import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.ui.geometry.Offset
import kotlin.math.abs

''' + body.replace('internal val ', '@kotlin.native.HiddenFromObjC\nval ').replace('internal fun ', '@kotlin.native.HiddenFromObjC\nfun ')
    return android, shared.rstrip() + '\n'


def extract_photo_preview_session(source):
    source = source.replace('\r\n', '\n')
    coordinator = section(source, '@OptIn(ExperimentalFoundationApi::class)\n@Composable\ninternal fun PhotoPreviewOverlay(',
                          '@Composable\ninternal fun SinglePhotoPreviewOverlay(')
    single = section(source, '@Composable\ninternal fun SinglePhotoPreviewOverlay(', '@Composable\nprivate fun BurstCollectionPreviewPage(')
    single_doc = coordinator[coordinator.index('/**\n * 单张内存位图的大图预览。'):]
    coordinator = replace_once(coordinator, single_doc, '')
    single = single_doc + single
    ghost = section(source, '@Composable\nprivate fun PreviewBurstQueueFlightGhost(', '@Composable\nprivate fun BurstCollectionExpandButton(')
    ghost = '/** 当前合集叠片沿单张预览完全相同的弧线收进队列胶囊。 */\n' + ghost
    adapters = section(source, 'private class AndroidPreviewPageImages', '/**\n * 照片大图共用')
    prefix = source[:source.index(coordinator)]
    constants = []
    for name in ('PREVIEW_DEFERRED_LOAD_DELAY_MS', 'PREVIEW_QUEUE_SWIPE_TRIGGER_DP', 'PREVIEW_QUEUE_FLIGHT_DURATION_MS',
                 'PREVIEW_QUEUE_GHOST_PREROLL_MS', 'PREVIEW_QUEUE_ANIMATION_TIMEOUT_MS'):
        line = next(line for line in source.splitlines(True) if line.startswith('private const val '+name+' = '))
        constants.append(line)
        prefix = replace_once(prefix, line, '')
    prefix = replace_once(prefix, 'import android.net.Uri\n', 'import android.net.Uri\nimport android.content.ContentResolver\nimport androidx.lifecycle.compose.collectAsStateWithLifecycle\n')
    adapters = replace_once(adapters, 'private class AndroidPreviewPageImages(private val cameraViewModel: CameraViewModel) : PreviewPageImages {',
        '''private class AndroidPreviewSession(
    private val cameraViewModel: CameraViewModel,
    private val contentResolver: ContentResolver,
) : PreviewSessionSource<Uri> {
''' + ANDROID_SESSION_METHODS.rstrip())
    adapters = replace_once(adapters, 'private object AndroidPreviewPageText : PreviewPageText {', '''private object AndroidPreviewPageText : PreviewSessionText {
    @Composable override fun burstLabel(): String = stringResource(R.string.burst_label)
    @Composable override fun protectedLabel(): String = stringResource(R.string.filter_protected)
    @Composable override fun histogramDescription(): String = stringResource(R.string.cd_preview_histogram)
    @Composable override fun rotationDescription(): String = stringResource(R.string.cd_rotate_photo)''')
    android = (prefix + wrapper(coordinator, WRAPPER_CALL) + single + adapters).rstrip() + '\n'

    # The whole original body stays in its original order. Only platform call sites change.
    shared = replace_once(coordinator, '@OptIn(ExperimentalFoundationApi::class)', '@kotlin.native.HiddenFromObjC\n@OptIn(ExperimentalFoundationApi::class)')
    shared = replace_once(shared, 'internal fun PhotoPreviewOverlay(', 'fun <Source : Any> SharedPhotoPreviewOverlay(')
    shared = replace_once(shared, '    cameraViewModel: CameraViewModel,', '''    session: PreviewSessionSource<Source>,
    text: PreviewSessionText,
    burstContent: PreviewBurstContent,
    backHandler: @Composable (Boolean, () -> Unit) -> Unit,''')
    shared = counted(shared, '-> Uri?', '-> Source?', 2)
    shared = counted(shared, 'mutableStateMapOf<Int, Uri>()', 'mutableStateMapOf<Int, Source>()', 2)
    shared = replace_once(shared, '    activeProgressFlow: StateFlow<ActiveTransferProgress?>,', '    activeProgress: @Composable () -> ActiveTransferProgress?,')
    shared = replace_once(shared, '    val contentResolver = LocalContext.current.contentResolver\n', '')
    shared = replace_once(shared, '    val cameraState by cameraViewModel.state.collectAsState()', '    val isConnectedToCamera = session.connected()')
    shared = counted(shared, 'cameraState.isConnectedToCamera', 'isConnectedToCamera', 4)
    shared = replace_once(shared, '    BackHandler(enabled = !closing) { startClose() }', '    backHandler(!closing, startClose)')
    shared = counted(shared, 'Math.floorMod(', 'previewFloorMod(', 2)
    shared = replace_once(shared, 'Math.toRadians(', 'previewRadians(')
    shared = replace_once(shared, 'Math.PI', 'kotlin.math.PI')
    shared = replace_once(shared, 'calculateLuminanceHistogram(histogramSource.asAndroidBitmap())', 'session.histogram(histogramSource)')
    shared = replace_once(shared, 'localOriginalPreviewRoute(file.extension)', 'session.localRoute(file.extension)')
    local_decode = section(shared, '                    withContext(Dispatchers.IO) {', '\n                } catch (cancelled: CancellationException)')
    shared = replace_once(shared, local_decode, '                    session.decodeLocal(localUri, localPreviewRoute)')
    for name, count in [('cachedThumbnail', 1), ('setFhdActive', 2), ('loadFhdPreview', 1), ('loadLocalExif', 1), ('loadExif', 1)]:
        shared = counted(shared, 'cameraViewModel.'+name+'(', 'session.'+('cached' if name=='cachedThumbnail' else name)+'(', count)
    shared = replace_once(shared, 'cameraViewModel.withInteractivePreviewPriority {', 'session.withInteractivePreviewPriority {')
    shared = replace_once(shared, '                    PreviewPage(', '                    SharedPhotoPreviewPage(')
    shared = replace_once(shared, '                        file = file,\n                        cameraViewModel = cameraViewModel,',
        '                        file = file,\n                        images = session, text = text, uptimeMillis = { session.uptimeMillis() },')
    shared = replace_once(shared, '                    BurstCollectionPreviewPage(', '                    SharedPreviewBurstPage(')
    shared = replace_once(shared, '                        collection = item,\n                        cameraViewModel = cameraViewModel,',
        '                        collection = item,\n                        content = burstContent,')
    shared = replace_once(shared, '            PreviewBurstQueueFlightGhost(', '            SharedPreviewBurstQueueFlightGhost(')
    shared = replace_once(shared, '                cameraViewModel = cameraViewModel,', '                content = burstContent,')
    shared = replace_once(shared, '                        TransferStatusIndicator(', '                        SharedTransferStatusIndicator(')
    shared = replace_once(shared, '                            activeProgressFlow = activeProgressFlow,', '                            activeProgress = activeProgress,')
    shared = replace_once(shared, 'stringResource(R.string.burst_label)', 'text.burstLabel()')
    shared = replace_once(shared, 'stringResource(R.string.filter_protected)', 'text.protectedLabel()')
    shared = replace_once(shared, '                    ExifMetadataBar(', '                    SharedPreviewExifMetadataBar(')
    shared = replace_once(shared, '                        BurstMemberCollapseButton(', '                        SharedPreviewBurstNavigationButton(\n                            expand = false, text = text,')
    shared = replace_once(shared, '                        PreviewHistogramButton(', '                        SharedPreviewHistogramButton(\n                            description = { text.histogramDescription() },')
    shared = replace_once(shared, '                        PreviewRotationButton(onClick = {', '                        SharedPreviewRotationButton(description = { text.rotationDescription() }, onClick = {')
    shared = counted(shared, '                    TransferQueueButton(', '                    SharedPreviewTransferQueueButton(\n                        text = text,', 2)
    shared = replace_once(shared, '                    BurstCollectionExpandButton(', '                    SharedPreviewBurstNavigationButton(\n                        expand = true, enabled = true, text = text,')

    ghost = replace_once(ghost, '@Composable\nprivate fun PreviewBurstQueueFlightGhost(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun SharedPreviewBurstQueueFlightGhost(')
    ghost = replace_once(ghost, '    cameraViewModel: CameraViewModel,', '    content: PreviewBurstContent,')
    ghost = replace_once(ghost, '        BurstCollectionStack(', '        SharedPreviewBurstStack(')
    ghost = replace_once(ghost, '            cameraViewModel = cameraViewModel,', '            content = content,')
    ghost = replace_once(ghost, 'Math.PI', 'kotlin.math.PI')
    imports = source[source.index('import '):source.index('// 视频扩展名')]
    for line in list(imports.splitlines(True)):
        if any(x in line for x in ('import android.', 'androidx.activity.', 'asAndroidBitmap', 'asImageBitmap', 'LocalContext',
                'androidx.compose.ui.res.', 'import com.ztransfer.R', 'PhotoFrameExporter', 'formatFileSize', 'CameraViewModel',
                'NIKON_RAW_EXTENSIONS', 'TIFF_EXTENSIONS', 'PtpConstants', 'kotlinx.coroutines.flow.StateFlow')):
            imports = replace_once(imports, line, '')
    shared = HEADER + imports + ''.join(constants) + '\n' + shared + ghost
    # Batch 42: both platform inputs delegate to one local-route rule. Original IO/date/UI stay here.
    android = replace_once(android, '''internal fun localOriginalPreviewRoute(extension: String): LocalOriginalPreviewRoute = when {
    extension in NIKON_RAW_EXTENSIONS -> LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG
    extension in TIFF_EXTENSIONS -> LocalOriginalPreviewRoute.CAMERA_FHD
    else -> LocalOriginalPreviewRoute.DIRECT_BITMAP
}''', '''internal fun localOriginalPreviewRoute(extension: String): LocalOriginalPreviewRoute =
    originalLocalPreviewRoute(extension)''')
    return android, add_async_preview_enqueue(shared.rstrip() + '\n'), CONTRACT
