"""Source regression checks; device smoothness is deliberately not asserted."""
from pathlib import Path
import subprocess
import unittest

from filter_overlay_extraction import extract_anchor_popup
from settings_popup_animation_fix import (
    apply_popup_motion, apply_wrapper_motion, restore_settings_motion,
)
from directory_ui_wiring import previous_directory_ui_source
import settings_controls_extraction as settings

ROOT = Path(__file__).resolve().parents[2]
POPUP = "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedAnchorPopup.kt"
WRAPPER = "app/src/main/java/com/ztransfer/ui/screen/AnchorPopup.kt"


def baseline(ref, path):
    return subprocess.check_output(["git", "show", ref + ":" + path], cwd=ROOT).decode("utf8")


class SettingsPopupAnimationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.popup = (ROOT / POPUP).read_text(encoding="utf8")
        cls.wrapper = (ROOT / WRAPPER).read_text(encoding="utf8")
        cls.settings = (ROOT / settings.ANDROID).read_text(encoding="utf8")

    def test_popup_and_wrapper_allow_only_reviewed_presentation_edits(self):
        old_wrapper, old_popup = extract_anchor_popup(baseline("55876fa", WRAPPER))
        self.assertEqual(apply_popup_motion(old_popup), self.popup)
        self.assertEqual(apply_wrapper_motion(old_wrapper), self.wrapper)

    def test_settings_state_persistence_and_io_remain_identical(self):
        expected, _ = settings.extract(baseline(settings.BASELINE, settings.ANDROID))
        restored = restore_settings_motion(self.settings)
        self.assertEqual(previous_directory_ui_source(settings.ANDROID, restored), expected)

    def test_morph_is_opt_in_and_content_constraints_are_preserved(self):
        self.assertIn("morphFromAnchor: Boolean = false", self.popup)
        self.assertIn("morphFromAnchor: Boolean = false", self.wrapper)
        self.assertEqual(self.settings.count("morphFromAnchor = true"), 1)
        self.assertIn("propagateMinConstraints = true", self.popup)
        self.assertIn("compositingStrategy = CompositingStrategy.Auto", self.popup)
        self.assertNotIn("CompositingStrategy.ModulateAlpha", self.popup)

    def test_close_can_interrupt_open_and_uses_latest_callback(self):
        self.assertIn("if (!animationState.closing)", self.popup)
        self.assertIn("!animationState.expansionStarted && !animationState.closing", self.popup)
        self.assertIn("(260 * progress.value).toInt().coerceAtLeast(1)", self.popup)
        self.assertIn("rememberUpdatedState(onDismiss)", self.popup)
        self.assertIn("currentOnDismiss()", self.popup)
        self.assertIn("backHandler { startClose() }", self.popup)

    def test_detail_navigation_is_short_and_reversed_on_return(self):
        self.assertIn("val pageTravel = with(density) { 24.dp.roundToPx() }", self.settings)
        self.assertIn("val direction = if (enteringEditor) 1 else -1", self.settings)
        self.assertIn("clip = true", self.settings)

    def test_both_entry_buttons_use_unchanged_standard_click_feedback(self):
        for name in ("HomeScreen.kt", "FileListScreen.kt"):
            path = "app/src/main/java/com/ztransfer/ui/screen/" + name
            current = (ROOT / path).read_text(encoding="utf8")
            self.assertEqual(current, baseline("9d1e77a", path))
            self.assertNotIn("settingsMorphSource", current)

    def test_no_neck_or_custom_button_progress_and_faster_open(self):
        self.assertNotIn("neckFraction", self.popup)
        self.assertNotIn("Path.combine", self.popup)
        self.assertNotIn("settingsMotion", self.popup + self.wrapper + self.settings)
        self.assertIn("drawRoundRect(colors.glassSurfaceHeavy", self.popup)
        self.assertIn("tween(320, easing = LinearEasing)", self.popup)

    def test_oracle_fails_closed_when_anchors_are_changed(self):
        with self.assertRaises(ValueError):
            apply_popup_motion(self.popup)
        with self.assertRaises(ValueError):
            apply_wrapper_motion(self.wrapper)
        with self.assertRaises(ValueError):
            restore_settings_motion(self.settings.replace("morphFromAnchor = true", "morphFromAnchor = false"))


if __name__ == "__main__":
    unittest.main()
