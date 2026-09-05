from pathlib import Path
import subprocess
import unittest
from thumbnail_grid_extraction import extract_thumbnail_grid, section
from transfer_page_extraction import extract_collapse_height
from signal_pill_extraction import extract_signal_pill
from queue_execution_extraction import extract_queue_execution
from filter_overlay_extraction import extract_filter_overlay
from export_exit_extraction import extract_export_exit


class ThumbnailGridExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]
        cls.original = subprocess.run(['git', 'show', '55876fa:app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt'],
            cwd=cls.root, check=True, capture_output=True, text=True, encoding='utf-8').stdout
        for transform in (extract_collapse_height, extract_signal_pill, extract_queue_execution):
            cls.original = transform(cls.original)[0]
        cls.android, cls.shared = extract_thumbnail_grid(cls.original)

    def test_android_whole_page_coordinator_is_untouched(self):
        def page(s):
            return section(s, 'fun FileListScreen(', '/** 与状态胶囊同材质的顶部队列操作按钮')
        self.assertEqual(page(self.android), page(self.original))

    def test_original_cache_keys_io_arguments_and_existing_export_revision(self):
        for key in ('LaunchedEffect(file.handle, transfersBusy, allowRemoteThumbnail)',
                    'LaunchedEffect(file.handle, transfersBusy, loadEnabled, allowRemoteThumbnail)',
                    'mutableStateOf(cameraViewModel.cachedThumbnail(file.handle))',
                    'cameraViewModel.loadThumbnail(file, allowRemoteThumbnail)',
                    'existingExportRevision,', 'organizeTransfersByDate,'):
            self.assertIn(key, self.android)
        self.assertIn('if (loadEnabled && thumbnail == null)', self.android)
        self.assertIn('val transferred = isTransferred(file)', self.shared)

    def test_progress_is_still_only_subscribed_inside_active_status_branch(self):
        self.assertEqual(1, self.shared.count('val liveProgress = activeProgress()'))
        block = section(self.shared, 'if (st == TransferStatus.TRANSFERING)', '// 其余状态：')
        self.assertIn('val liveProgress = activeProgress()', block)
        self.assertIn('?.takeIf { it.taskId == task.taskId }', block)
        self.assertIn('activeProgress = { activeProgressFlow.collectAsStateWithLifecycle().value }', self.android)

    def test_real_keys_bounds_disposal_gestures_and_animation_callbacks_remain(self):
        for expression in ('override val key: Any = file.handle', 'burstCollectionGridKey(id)',
                           'contentType = { _, item -> item.reuseContentType }',
                           'DisposableEffect(file.handle, cellBoundsRegistry)',
                           'cellBoundsRegistry.remove(file.handle)', 'DisposableEffect(collectionId)',
                           'onDispose { onBoundsChanged(null) }', 'enabled = !exiting,',
                           'if (tapToPreview) onTapFile(file)', 'latestOnExitFinished(file.handle)',
                           'hiddenExitingHandles.forEach(onExportExitFinished)',
                           'if (b.width > 0f && b.height > 0f)', 'val lastVisible = groupItems.indexOfLast'):
            self.assertIn(expression, self.shared)

    def test_animated_text_stays_composable_and_uses_current_frame_count(self):
        self.assertIn('text = text.burstCount(animatedCount)', self.shared)
        self.assertIn('text.expand(!expanded)', self.shared)
        self.assertIn('stringResource(R.string.burst_collection_count, count)', self.android)
        self.assertIn('stringResource(R.string.filter_protected)', self.android)
        for platform_name in ('CameraViewModel,', 'ExportedOriginalIndex', 'stringResource(', 'collectAsStateWithLifecycle('):
            self.assertNotIn(platform_name, self.shared)

    def test_numeric_and_algorithm_differences_cannot_be_hidden(self):
        for old, new in [('lastVisible + 1 + columns', 'lastVisible + columns'),
                         ('val displayedItems = if (collapsingThis)', 'val displayedItems = if (!collapsingThis)'),
                         ('BURST_REFLOW_DURATION_MS = 300', 'BURST_REFLOW_DURATION_MS = 301'),
                         ('targetValue = if (expanded) 180f else 0f', 'targetValue = if (expanded) 181f else 0f')]:
            self.assertNotEqual(extract_thumbnail_grid(self.original.replace(old, new))[1], self.shared)

    def test_grid_constants_have_one_shared_definition(self):
        self.assertNotIn('const val CAMERA_REMOVAL_REFLOW_DURATION_MS', self.android)
        self.assertIn('const val CAMERA_REMOVAL_REFLOW_DURATION_MS = 280', self.shared)
        self.assertIn('delay((CAMERA_REMOVAL_REFLOW_DURATION_MS + 48).toLong())', self.android)
        self.assertNotIn('private data class CollapsingGroup(', self.android)
        self.assertNotIn('private val THUMBNAIL_THEME_BORDER_WIDTH', self.android)

    def test_android_and_shared_files_exactly_match_full_extraction(self):
        self.assertEqual(extract_export_exit(extract_filter_overlay(self.android)[0])[0], (self.root / 'app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt').read_text(encoding='utf-8'))
        self.assertEqual(self.shared, (self.root / 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedThumbnailGrid.kt').read_text(encoding='utf-8'))
