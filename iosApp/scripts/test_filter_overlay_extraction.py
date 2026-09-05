from pathlib import Path
import subprocess
import unittest
from filter_overlay_extraction import extract_filter_overlay, extract_anchor_popup, expected_contract
from thumbnail_grid_extraction import extract_thumbnail_grid, section
from transfer_page_extraction import extract_collapse_height
from signal_pill_extraction import extract_signal_pill
from queue_execution_extraction import extract_queue_execution
from export_exit_extraction import extract_export_exit
from photo_preview_session_extraction import extract_queue_flight


class FilterOverlayExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]
        def baseline(path):
            return subprocess.run(['git', 'show', '55876fa:'+path], cwd=cls.root, check=True,
                capture_output=True, text=True, encoding='utf-8').stdout
        cls.original = baseline('app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt')
        for transform in (extract_collapse_height, extract_signal_pill, extract_queue_execution, extract_thumbnail_grid):
            cls.original = transform(cls.original)[0]
        cls.android, cls.shared = extract_filter_overlay(cls.original)
        cls.popup_original = baseline('app/src/main/java/com/ztransfer/ui/screen/AnchorPopup.kt')
        cls.popup_android, cls.popup_shared = extract_anchor_popup(cls.popup_original)

    def test_all_generated_files_equal_full_baseline_transform(self):
        for path, expected in [
            ('app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt', extract_queue_flight(extract_export_exit(self.android)[0])[0]),
            ('app/src/main/java/com/ztransfer/ui/screen/AnchorPopup.kt', self.popup_android),
            ('shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedFilterOverlay.kt', self.shared),
            ('shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedAnchorPopup.kt', self.popup_shared),
            ('shared/src/commonMain/kotlin/com/ztransfer/ui/screen/FilterOverlayContract.kt', expected_contract()),
        ]:
            self.assertEqual(expected, (self.root/path).read_text(encoding='utf-8'), path)

    def test_android_coordinator_and_calendar_helpers_unchanged(self):
        start, end = 'fun FileListScreen(', '/** 与状态胶囊同材质的顶部队列操作按钮'
        self.assertEqual(section(self.android, start, end), section(self.original, start, end))
        start, end = 'private fun LocalDate.withClampedDate(', '/**\n * 筛选面板的选中态胶囊'
        helpers = section(self.original, start, end).replace('withClampedDate(', 'androidClampedDate(')
        self.assertIn(helpers, self.android)
        for expression in ('LocalDate.now()', 'YearMonth.of(year, month).lengthOfMonth()',
                           'PhotoDateRange.between(first, second)', 'compactDateRangeLabel(range)',
                           'LocalConfiguration.current.screenWidthDp.dp', 'BackHandler(onBack = close)'):
            self.assertIn(expression, self.android)

    def test_drafts_normalization_and_explicit_apply_preserved(self):
        for expression in ('remember(current) { mutableStateOf(current) }',
                           'next.isEmpty() -> null', 'next.containsAll(availableExts) -> null',
                           'if (next == working) return', 'var start by remember {', 'var end by remember {',
                           'if (next.isAfter(end)) end = next', 'if (next.isBefore(start)) start = next',
                           'onValueCommitted = { onDateChanged(date.withClampedDate(month = it)) }',
                           'onClick = { onApply(between(start, end)) }'):
            self.assertIn(expression, self.shared)

    def test_popup_full_body_except_back_registration_unchanged(self):
        body = self.popup_original[self.popup_original.index('    val colors = AppTheme.colors'):]
        self.assertEqual(body.replace('BackHandler { startClose() }', 'backHandler { startClose() }'),
                         self.popup_shared[self.popup_shared.index('    val colors = AppTheme.colors'):])
        self.assertIn('BackHandler(onBack = close)', self.popup_android)

    def test_geometry_animation_and_input_regressions_are_detected(self):
        for old, new in [('FILTER_PANEL_MAX_WIDTH = 360.dp', 'FILTER_PANEL_MAX_WIDTH = 361.dp'),
                         ('fadeIn(tween(150))', 'fadeIn(tween(151))'),
                         ('next.isEmpty() -> null', 'next.isEmpty() -> emptySet()'),
                         ('mutableStateOf(current?.start ?: initial)', 'mutableStateOf(initial)'),
                         ('Modifier.weight(1.3f)', 'Modifier.weight(1f)')]:
            self.assertIn(old, self.original)
            self.assertNotEqual(extract_filter_overlay(self.original.replace(old, new))[1], self.shared)

    def test_no_android_platform_dependencies_in_common_ui(self):
        for forbidden in ('java.time', 'LocalConfiguration', 'stringResource(', 'PhotoDateRange', 'LocalDate', 'R.string'):
            self.assertNotIn(forbidden, self.shared)
        self.assertNotIn('androidx.activity', self.popup_shared)
