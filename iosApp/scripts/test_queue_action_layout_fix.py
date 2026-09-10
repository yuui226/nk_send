"""Regression guards for the two intentional queue UI changes; not a device screenshot test."""
from pathlib import Path
import re
import subprocess
import unittest

from transfer_card_extraction import extract_transfer_cards
from transfer_page_extraction import extract_transfer_page
from queue_action_layout_fix import apply_cards_fix, apply_page_fix

ROOT = Path(__file__).resolve().parents[2]
COMMON = ROOT / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen"

class QueueActionLayoutTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        baseline = subprocess.check_output(
            ["git", "show", "55876fa:app/src/main/java/com/ztransfer/ui/screen/TransferScreen.kt"],
            cwd=ROOT).decode("utf8")
        # Existing, separately approved Compose placement API migration.
        baseline = baseline.replace(".animateItemPlacement(Motion.itemPlacement)",
            ".animateItem(\n                                fadeInSpec = null,\n"
            "                                placementSpec = Motion.itemPlacement,\n"
            "                                fadeOutSpec = null,\n                            )")
        android, cls.old_cards = extract_transfer_cards(baseline)
        _, cls.old_page = extract_transfer_page(android)
        cls.cards = (COMMON / "TransferCardComponents.kt").read_text(encoding="utf8")
        cls.page = (COMMON / "SharedTransferScreen.kt").read_text(encoding="utf8")

    def test_complete_sources_allow_only_the_two_reviewed_layout_fixes(self):
        self.assertEqual(apply_cards_fix(self.old_cards), self.cards)
        self.assertEqual(apply_page_fix(self.old_page), self.page)

    def test_retry_is_outside_text_box_in_the_centered_action_row(self):
        old_anchor = "modifier = Modifier.align(Alignment.TopEnd),"
        self.assertIn(old_anchor, self.old_page)
        self.assertNotIn(old_anchor, self.page)
        self.assertIn("verticalAlignment = Alignment.CenterVertically", self.page)
        self.assertIn("Modifier.fillMaxWidth())\n                                }\n\n"
            "                                // Both actions", self.page)
        self.assertNotIn("if (isFailed) Modifier.padding(end = 42.dp)", self.cards)
        self.assertIn("modifier = Modifier.padding(start = 10.dp)", self.page)

    def test_confirmation_is_a_separate_popup_with_dismissal_and_exit_animation(self):
        start = self.cards.index("fun SharedQueueConfirmFab(")
        end = self.cards.index("private fun ConfirmCard(", start)
        fab = self.cards[start:end]
        self.assertIn("Popup(", fab)
        self.assertIn("PopupProperties(focusable = true)", fab)
        self.assertIn("popupPositionProvider = QueueConfirmationPositionProvider", fab)
        self.assertIn("onDismissRequest = onDismiss", fab)
        self.assertIn("confirmationVisibility.currentState || confirmationVisibility.targetState", fab)
        self.assertIn("visibleState = confirmationVisibility", fab)
        self.assertEqual(fab.count("Spacer(modifier = Modifier.height(12.dp))"), 1)
        self.assertEqual(fab.count("GlassButton("), 1)

    def test_business_action_sequence_and_visibility_gates_are_unchanged(self):
        # Extract invocations, ignoring only indentation changed by moving the button.
        actions = lambda text: re.findall(r"actions\.[^\n]+", text)
        self.assertEqual(actions(self.old_page), actions(self.page))
        for gate in ("task.status == TransferStatus.FAILED",
                     "(connected || isOriginalTransferred(task))",
                     "hasRetryable && (connected || !retryNeedsCamera)",
                     "!task.isGeneratingFrame"):
            self.assertEqual(self.old_page.count(gate), self.page.count(gate))
        self.assertEqual(self.old_page[self.old_page.index("        // ---------- 右下角悬浮控件"):],
                         self.page[self.page.index("        // ---------- 右下角悬浮控件"):])

    def test_oracle_rejects_missing_or_already_applied_fixes(self):
        with self.assertRaises(ValueError):
            apply_page_fix(self.page)
        with self.assertRaises(ValueError):
            apply_cards_fix(self.cards)
