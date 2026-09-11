from pathlib import Path
import subprocess
import unittest
from photo_preview_session_extraction import extract_photo_preview_session, extract_queue_flight
from photo_viewport_extraction import extract_photo_viewport
from photo_preview_model_extraction import extract_photo_preview_model
from photo_preview_display_extraction import extract_photo_preview_display
from histogram_extraction import extract_histogram_button
from thumbnail_grid_extraction import section

ROOT = Path(__file__).resolve().parents[2]
BASE = 'app/src/main/java/com/ztransfer/ui/screen/'
SHARED = 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/'


class PhotoPreviewSessionExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        def original(name):
            return subprocess.run(['git', 'show', '55876fa:' + BASE + name], cwd=ROOT,
                check=True, capture_output=True, text=True, encoding='utf-8').stdout
        cls.source = extract_histogram_button(extract_photo_preview_display(extract_photo_preview_model(
            extract_photo_viewport(original('PhotoPreview.kt'), original('PreviewRotationButton.kt'))[0])[0])[0])[0]
        cls.android, cls.shared, cls.contract = extract_photo_preview_session(cls.source)
        cls.original_list = original('FileListScreen.kt')

    def test_full_original_coordinator_and_remaining_android_adapters_are_exact(self):
        for path, expected in [(BASE+'PhotoPreview.kt', self.android),
                               (SHARED+'SharedPhotoPreviewOverlay.kt', self.shared),
                               (SHARED+'PreviewSessionPlatform.kt', self.contract),
                               (SHARED+'QueueFlightCurve.kt', extract_queue_flight(self.original_list)[1])]:
            self.assertEqual(expected, (ROOT/path).read_text(encoding='utf-8'), path)
        self.assertNotIn('suspend fun loadHighResolutionPage(', self.android)
        self.assertNotIn('fun startPreviewQueueFlight(', self.android)
        self.assertNotIn('private fun PreviewPage(', self.android)
        self.assertNotIn('private fun PreviewBurstQueueFlightGhost(', self.android)

    def test_android_entry_signature_defaults_and_source_identity_are_preserved(self):
        anchor = 'internal fun PhotoPreviewOverlay('
        def signature(text): return text[text.index(anchor):text.index(') {', text.index(anchor))+3]
        self.assertEqual(signature(self.source), signature(self.android))
        self.assertIn('PreviewSessionSource<Uri>', self.android)
        self.assertIn('fun <Source : Any> SharedPhotoPreviewOverlay(', self.shared)
        self.assertIn('snapshotPreviewSessionSources(items, localOriginalUriFor)', self.shared)
        self.assertEqual(2, self.shared.count('mutableStateMapOf<Int, Source>()'))
        for text in ('cachedLocalUri != localUri', 'localDecodeFailures[h] != localUri',
                     'localPreviewUris[h] = localUri', 'localDecodeFailures[h] = localUri'):
            self.assertIn(text, self.shared)
        self.assertNotIn('localUri.toString()', self.shared)

    def test_current_local_then_camera_priority_exif_then_neighbors_keep_original_order(self):
        body = section(self.shared, '        val loadedCurrent = loadHighResolutionPage(',
                       '    // 上面的主加载不能把 transfersBusy')
        ordered = ['allowCameraRequest = false', 'if (resolvedLocally)', 'loadExifPage(cp)',
                   'session.withInteractivePreviewPriority {', 'allowCameraRequest = true',
                   'val allowNeighborCameraRequest = !currentTransfersBusy', 'page = cp - 1', 'page = cp + 1']
        positions = [body.index(text) for text in ordered]
        self.assertEqual(positions, sorted(positions))
        exif = section(self.shared, '    suspend fun loadExifPage(', '    // 即时淘汰')
        self.assertIn('session.loadLocalExif(file, localUri)', exif)
        self.assertIn('session.loadExif(file)', exif)
        self.assertIn('finally {\n            exifLoading.remove(h)', exif)

    def test_original_effect_keys_do_not_cancel_current_ptp_on_transfer_state_change(self):
        expected = '''    LaunchedEffect(
        previewItems,
        pagerState.currentPage,
        currentHandle,
        currentLocalOriginalUri,
        isConnectedToCamera,
        deferredLoadsEnabled
    )'''
        self.assertIn(expected, self.shared)
        for text in ('LaunchedEffect(transfersBusy)', 'previousTransfersBusy && !transfersBusy',
                     'val keep = (cp - 2).coerceAtLeast(0)..(cp + 2).coerceAtMost(previewItems.lastIndex)',
                     'LaunchedEffect(previewItems, pagerState.currentPage, currentHandle)',
                     'delay(PREVIEW_DEFERRED_LOAD_DELAY_MS)', 'PREVIEW_DEFERRED_LOAD_DELAY_MS = 340L'):
            self.assertIn(text, self.shared)

    def test_original_local_decode_exceptions_and_camera_unavailable_semantics_are_retained(self):
        load = section(self.shared, '    suspend fun loadHighResolutionPage(', '    // 加载单页 EXIF')
        for text in ('while (highResolutionLoading.containsKey(h) && h !in highResolutionBitmaps) delay(16)',
                     'catch (cancelled: CancellationException) {\n                    throw cancelled',
                     'catch (_: Exception) {\n                    null', 'if (!allowCameraRequest) return false',
                     'val res = session.loadFhdPreview(file) ?: run {', 'fhdUnavailable[h] = true',
                     'finally {\n            highResolutionLoading.remove(h)'):
            self.assertIn(text, load)
        for text in ('withContext(Dispatchers.IO)', 'PhotoFrameExporter.decodeRawEmbeddedPreview(contentResolver, source)',
                     'PhotoFrameExporter.decodeOriginalPreview(contentResolver, source)', 'bitmap?.asImageBitmap()',
                     'cameraViewModel.loadLocalExif(file, source)', 'cameraViewModel.withInteractivePreviewPriority(block)'):
            self.assertIn(text, self.android)

    def test_original_lifecycle_progress_text_and_histogram_remain_platform_calls_in_place(self):
        for text in ('DisposableEffect(Unit)', 'session.setFhdActive(true)', 'onDispose { session.setFhdActive(false) }',
                     'backHandler(!closing, startClose)', 'session.histogram(histogramSource)',
                     'SharedTransferStatusIndicator(', 'activeProgress = activeProgress,'):
            self.assertIn(text, self.shared)
        for text in ('activeProgress = { activeProgressFlow.collectAsStateWithLifecycle().value }',
                     'val cameraState by cameraViewModel.state.collectAsState()',
                     'backHandler = { enabled, onBack -> BackHandler(enabled, onBack) }',
                     'calculateLuminanceHistogram(bitmap.asAndroidBitmap())',
                     'stringResource(R.string.cd_preview_histogram)', 'stringResource(R.string.cd_rotate_photo)'):
            self.assertIn(text, self.android)
        for forbidden in ('import android.', 'CameraViewModel', 'java.', 'R.string', 'Dispatchers.IO', 'asAndroidBitmap'):
            self.assertNotIn(forbidden, self.shared)

    def test_burst_return_and_flight_callbacks_keep_original_order_and_cache_only_ghost(self):
        for text in ('if (!enqueue()) return', 'withTimeoutOrNull(PREVIEW_QUEUE_ANIMATION_TIMEOUT_MS)',
                     'PREVIEW_QUEUE_ANIMATION_TIMEOUT_MS = 1_000L', 'delay(PREVIEW_QUEUE_GHOST_PREROLL_MS)',
                     'PREVIEW_QUEUE_GHOST_PREROLL_MS = 32L', 'PREVIEW_QUEUE_FLIGHT_DURATION_MS = 560',
                     'currentOnQueueFlightCaught()', 'queueMotionJob?.cancel()', 'finally {\n                queueOffsetY = 0f'):
            self.assertIn(text, self.shared)
        self.assertLess(self.shared.index('pagerState.scrollToPage(collectionPage)'), self.shared.index('previewItems = collapsePreviewBurst('))
        ghost = self.shared[self.shared.index('fun SharedPreviewBurstQueueFlightGhost('):]
        self.assertIn('loadEnabled = false', ghost)
        self.assertIn('SharedPreviewBurstStack(', ghost)
        self.assertNotIn('loadThumbnail', ghost)
        self.assertIn('previewFloorMod(initialRotationQuarterTurns, 4)', self.shared)
        self.assertIn('previewFloorMod((-nextDegrees / 90f).toInt(), 4)', self.shared)

    def test_timing_order_keys_loading_gates_and_curve_mutations_are_never_normalized(self):
        for before, after in [('PREVIEW_DEFERRED_LOAD_DELAY_MS = 340L', 'PREVIEW_DEFERRED_LOAD_DELAY_MS = 341L'),
                              ('if (!enqueue()) return', 'if (enqueue()) return'),
                              ('page = cp - 1', 'page = cp + 1'),
                              ('(cp - 2).coerceAtLeast(0)', '(cp - 3).coerceAtLeast(0)'),
                              ('LaunchedEffect(transfersBusy)', 'LaunchedEffect(transfersBusy, currentHandle)'),
                              ('localDecodeFailures[h] != localUri', 'localDecodeFailures[h] == localUri')]:
            with self.subTest(before=before):
                self.assertIn(before, self.source)
                self.assertNotEqual((self.android, self.shared, self.contract),
                                    extract_photo_preview_session(self.source.replace(before, after)))
        for before, after in [('CubicBezierEasing(0.5f, 0f, 0.8f, 0.35f)', 'CubicBezierEasing(0.6f, 0f, 0.8f, 0.35f)'),
                              ('0.35f * dx', '0.36f * dx'), ('4f * minApexYPx', '3f * minApexYPx')]:
            self.assertNotEqual(extract_queue_flight(self.original_list)[1],
                                extract_queue_flight(self.original_list.replace(before, after))[1])

    def test_platform_floor_mod_retains_android_intrinsic_and_native_positive_modulo(self):
        android=(ROOT/'shared/src/androidMain/kotlin/com/ztransfer/ui/screen/PreviewPlatform.android.kt').read_text(encoding='utf-8')
        native=(ROOT/'shared/src/iosMain/kotlin/com/ztransfer/ui/screen/PreviewPlatform.ios.kt').read_text(encoding='utf-8')
        self.assertIn('= Math.floorMod(value, divisor)', android)
        self.assertIn('= value.mod(divisor)', native)
        self.assertEqual(2, self.shared.count('previewFloorMod('))
        self.assertIn('SharedPreviewBurstQueueFlightGhost(', self.shared)
        self.assertNotIn('单张内存位图的大图预览', self.shared)
