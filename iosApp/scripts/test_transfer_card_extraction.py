import subprocess
import unittest
from pathlib import Path
from transfer_card_extraction import extract_transfer_cards, replace_once


class TransferCardExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.baseline = subprocess.run(["git", "show", "55876fa:app/src/main/java/com/ztransfer/ui/screen/TransferScreen.kt"],
            cwd=Path(__file__).resolve().parents[2], check=True, capture_output=True, text=True, encoding="utf-8").stdout
        cls.android, cls.common = extract_transfer_cards(cls.baseline)

    def test_queue_business_body_is_byte_identical(self):
        def body(text):
            start = text.index("fun TransferScreen(")
            end = text.index("\n@Composable\nprivate fun TransferRetryButton(", start)
            if "private fun transferCardVisualState(" in text[start:end]:
                end = text.index("private fun transferCardVisualState(", start)
            return text[start:end].rstrip()
        self.assertEqual(body(self.baseline), body(self.android))

    def test_android_formatting_and_thumbnail_effect_keys_stay_original(self):
        for expression in ('"%.1f MB/s".format(task.downloadMBps)',
            "task.elapsedMs?.let(::formatDuration)", "displayedFrameGenerationElapsedMs?.let(::formatDuration)",
            "remember(file.handle)", "LaunchedEffect(file.handle, retryNudge)", "cameraViewModel.loadThumbnail(file)",
            "task.file.size != PtpConstants.SIZE_UNKNOWN -> formatFileSize(task.file.size)"):
            self.assertIn(expression, self.baseline)
            self.assertIn(expression, self.android)

    def test_shared_has_no_camera_loading_or_platform_resources(self):
        for forbidden in ("import android.", "import com.ztransfer.R", "stringResource(",
                          "cameraViewModel.loadThumbnail", ".format(", "getCamera", "removeTask("):
            self.assertNotIn(forbidden, self.common)
        self.assertIn("text = text.failureText", self.common)
        self.assertIn("onClick = onConfirm", self.common)
        self.assertIn("onClick = onDismiss", self.common)

    def test_unknown_or_duplicate_anchors_fail_closed(self):
        with self.assertRaises(ValueError):
            replace_once("a a", "a", "b")
        with self.assertRaises(ValueError):
            replace_once("x", "a", "b")

    def test_rendering_constants_are_not_normalized(self):
        changed = self.baseline.replace("iconPop.snapTo(0.62f)", "iconPop.snapTo(0.63f)")
        self.assertNotEqual(extract_transfer_cards(changed)[1], self.common)
