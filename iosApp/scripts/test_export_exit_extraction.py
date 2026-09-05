from pathlib import Path
import unittest
from export_exit_extraction import extract_export_exit
from photo_preview_session_extraction import extract_queue_flight
import test_filter_overlay_extraction as filter_baseline


class ExportExitExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        filter_baseline.FilterOverlayExtractionTest.setUpClass()
        cls.root = Path(__file__).resolve().parents[2]
        cls.source = filter_baseline.FilterOverlayExtractionTest.android
        cls.android, cls.shared = extract_export_exit(cls.source)

    def test_complete_android_page_and_shared_coordinator_match_explicit_extraction(self):
        self.assertEqual(extract_queue_flight(self.android)[0], (self.root/'app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt').read_text(encoding='utf-8'))
        self.assertEqual(self.shared, (self.root/'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/ExportExitUiState.kt').read_text(encoding='utf-8'))

    def test_same_original_state_is_used_by_both_platform_pages(self):
        native = (self.root/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt').read_text(encoding='utf-8')
        self.assertIn('rememberExportExitState(transferState.tasks, filterUntransferred, exportedHandlesForFilter)', self.android)
        self.assertIn('rememberExportExitState(tasks.tasks, criteria.untransferredOnly && originals.ready, exportedHandles)', native)
        for expression in ('onExportExitFinished = exportExit.onExitFinished', 'exitingExportHandles = exportExit.exitingHandles'):
            self.assertIn(expression, native); self.assertIn(expression, self.android)

    def test_historical_exports_hide_immediately_and_new_completions_finish_before_filtering(self):
        for expression in ('mutableStateOf(exportedHandlesForFilter.intersect(animatedExportCandidates))',
                           '(exportedHandlesForFilter - animatedExportCandidates) + finishedExportExitHandles',
                           '.minus(exitingExportHandles.keys)', 'finishedExportExitHandles = finishedExportExitHandles + handle',
                           'exitingExportHandles.remove(handle)', 'exportReflowTick++', 'delay(320)'):
            self.assertIn(expression, self.shared)

    def test_timing_and_status_changes_cannot_be_hidden_by_the_guard(self):
        for old, new in [('delay(320)', 'delay(321)'), ('it.status == TransferStatus.WAITING', 'it.status == TransferStatus.FAILED'),
                         ('finishedExportExitHandles + handle', 'finishedExportExitHandles - handle')]:
            self.assertNotEqual(extract_export_exit(self.source.replace(old, new))[1], self.shared)

    def test_android_keeps_untransferred_available_by_default_while_native_waits_for_index(self):
        shared = (self.root/'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedFilterOverlay.kt').read_text(encoding='utf-8')
        native = (self.root/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt').read_text(encoding='utf-8')
        self.assertIn('untransferredEnabled: Boolean = true', shared)
        self.assertIn('enabled = untransferredEnabled', shared)
        self.assertIn('untransferredEnabled = originals.ready', native)
        self.assertIn('SharedFilterOverlay(', native)
        self.assertNotIn('untransferredEnabled =', self.android)
