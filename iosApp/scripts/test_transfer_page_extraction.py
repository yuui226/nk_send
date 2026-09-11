import subprocess
import unittest
from pathlib import Path
from transfer_card_extraction import extract_transfer_cards
from transfer_page_extraction import extract_transfer_page, extract_collapse_height


class TransferPageExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]
        cls.baseline = cls.original("TransferScreen.kt")
        cls.cards_android, _ = extract_transfer_cards(cls.baseline)
        cls.android, cls.common = extract_transfer_page(cls.cards_android)

    @classmethod
    def original(cls, name):
        return subprocess.run(["git", "show", f"55876fa:app/src/main/java/com/ztransfer/ui/screen/{name}"],
            cwd=cls.root, check=True, capture_output=True, text=True, encoding="utf-8").stdout

    def test_high_frequency_collection_remains_inside_active_item(self):
        start = self.common.index("items(transferState.tasks.asReversed()")
        active = self.common.index("if (task.status == TransferStatus.TRANSFERING)", start)
        collect = self.common.index("activeTransferProgress.collectAsState()")
        self.assertGreater(collect, active)
        self.assertEqual(self.common.count("collectAsState()"), 1)
        self.assertIn("progress?.takeIf { it.taskId == taskId }", self.common)

    def test_clear_sequence_and_live_read_are_preserved(self):
        positions = [self.common.index(value) for value in (
            "actions.withdrawPending()", "transferState.tasks.forEach", "delay(320)",
            "actions.removeCleared()", "actions.currentTasks()")]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("currentTasks = { transferViewModel.state.value.tasks }", self.android)
        self.assertIn("existingExportRevision = transferState.existingExportRevision", self.android)

    def test_removal_race_and_retry_exclusions_are_preserved(self):
        self.assertIn("removeProgress.animateTo(0f, tween(280, easing = FastOutSlowInEasing))", self.common)
        self.assertIn("if (!actions.removeTask(taskId))", self.common)
        self.assertIn("removeProgress.animateTo(1f, tween(200, easing = FastOutSlowInEasing))", self.common)
        self.assertIn("actions.retryFailed(removingTaskIds.keys.toSet())", self.common)
        self.assertIn("task.status != TransferStatus.TRANSFERING &&", self.common)
        self.assertIn("!task.isGeneratingFrame", self.common)

    def test_clock_loader_formatters_and_camera_provider_stay_android(self):
        for value in ("android.os.SystemClock::elapsedRealtime", "BackHandler(enabled = backHandlerEnabled",
            "remember(file.handle)", "LaunchedEffect(file.handle, retryNudge)",
            "cameraViewModel.loadThumbnail(file)", '"%.1f MB/s".format(task.downloadMBps)',
            "transferViewModel.retrySingleTask(it, cameraViewModel::getCamera)",
            "transferViewModel.retryFailed(cameraViewModel::getCamera, excludedTaskIds = it)"):
            self.assertIn(value, self.android)
        self.assertEqual(self.common.count("elapsedRealtimeMs()"), 2)

    def test_no_platform_dependency_leaks_to_common_page(self):
        for value in ("import android.", "com.ztransfer.R", "ViewModel", "stringResource(", "getCamera"):
            self.assertNotIn(value, self.common)
        self.assertIn("thumbnail(task.file, transferState.isTransferring", self.common)
        self.assertIn("isOriginalTransferred(it)", self.common)
        self.assertIn("isOriginalTransferred(task)", self.common)

    def test_unknown_clock_anchor_fails_closed(self):
        with self.assertRaises(ValueError):
            extract_transfer_page(self.cards_android.replace("android.os.SystemClock.elapsedRealtime()", "changedClock()", 1))

    def test_layout_numbers_are_not_normalized(self):
        changed = self.cards_android.replace("delay(320)", "delay(321)")
        self.assertNotEqual(extract_transfer_page(changed)[1], self.common)
        original = self.original("FileListScreen.kt")
        android, common = extract_collapse_height(original)
        self.assertNotIn("fun Modifier.collapseHeight", android)
        self.assertIn("layout(placeable.width, (placeable.height * p).roundToInt())", common)
        self.assertIn("placeable.placeRelativeWithLayer(0, 0) { alpha = p }", common)
