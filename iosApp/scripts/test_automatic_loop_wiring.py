"""W06 source/registration contracts. These do not execute Swift or substitute for XCTest."""
from pathlib import Path
import subprocess
import unittest
from parallel_batch_wiring import AUTOMATIC_LOOP_CHANGES

ROOT = Path(__file__).resolve().parents[2]
PROBE = "iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift"


class AutomaticLoopWiringTest(unittest.TestCase):
    def test_only_reviewed_session_guard_changes_production_owner(self):
        source = (ROOT / PROBE).read_text(encoding="utf-8")
        from connection_product_wiring import previous_connection_product_source
        source = previous_connection_product_source(PROBE, source)
        for current, previous in AUTOMATIC_LOOP_CHANGES:
            self.assertEqual(source.count(current), 1)
            source = source.replace(current, previous, 1)
        baseline = subprocess.check_output(["git", "show", "3cc239d:" + PROBE], cwd=ROOT).decode()
        self.assertEqual(source, baseline)

    def test_one_subscription_and_generation_guard_precede_page_publication(self):
        source = (ROOT / PROBE).read_text(encoding="utf-8")
        self.assertEqual(source.count("for await snapshot in queue.updates"), 1)
        self.assertNotIn("onAccepted:", source)
        body = source.split("private func publishQueueSnapshot(", 1)[1].split("private func receiveCatalogAddition", 1)[0]
        self.assertLess(body.index("guard apConnection?.connectionID"), body.index("queueSnapshot = snapshot"))
        self.assertLess(body.index("previous.sequence > snapshot.sequence"), body.index("queueSnapshot = snapshot"))
        self.assertIn("queuePage?.publish(snapshot)", body)
        self.assertIn("filesPage?.publishQueue(snapshot)", body)

    def test_six_registered_apple_scenarios_use_real_download_provider_and_page(self):
        source = (ROOT / "iosApp/ZTransferTests/CameraNetworkTests.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("@MainActor func testAutomaticLoop"), 6)
        body = source.split("@MainActor private func automaticPublicationLoop(", 1)[1].split("private func resolverInfo", 1)[0]
        for token in ["CameraAutomaticTransferCoordinator(", "CameraOriginalQueue(", "CameraOriginalStore(",
                      "ProviderOriginalStore(", "OriginalFilesPageBridge(", "onAddition: { await automatic.receive($0) }",
                      "catalog.refresh(detectNewHandles: true)", "await queue.retryFailed(excluding: [])",
                      "XCTAssertEqual(wire.sent().count, downloaded)", "page.originalRevision == index.revision",
                      "XCTAssertEqual(index.entries.count, 2)", "XCTAssertEqual(repeated.rows.map",
                      "XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), bytes)"]:
            self.assertIn(token, body)
        self.assertIn("for await snapshot in queue.updates", body)
        self.assertNotIn("page.publishQueue(done)", body)  # Must arrive through the live subscription.
        project = (ROOT / "iosApp/ZTransfer.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        self.assertIn("CameraNetworkTests.swift in Sources", project)

    def test_android_shared_logic_and_packaging_are_unchanged_this_task(self):
        changes = subprocess.check_output(
            ["git", "diff", "3cc239d", "--name-only", "--", "app", "shared", "platform", "dist", "dist-debug",
             "build.gradle.kts", "settings.gradle.kts", "gradle"], cwd=ROOT).decode().strip()
        import home_card_extraction as home
        home.verify()
        allowed = {home.ANDROID, home.COMMON,
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHomeText.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeConnectionHomeTest.kt"}
        self.assertLessEqual(set(changes.splitlines()), allowed)


if __name__ == "__main__":
    unittest.main()
