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
        import sta_media_extraction as sta
        sta.verify()
        import thumbnail_crop_extraction as crop
        crop.verify()
        import queue_workspace_extraction as workspace
        import workspace_transition_extraction as transition
        workspace.verify(); transition.verify()
        allowed = {home.ANDROID, home.COMMON, sta.ANDROID, sta.COMMON, crop.ANDROID, crop.COMMON,
            "shared/src/commonMain/kotlin/com/ztransfer/catalog/ThumbnailFillQueue.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeThumbnailFillQueue.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/preview/PreviewExifRationalReader.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/preview/PreviewExifSupplement.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/catalog/NativeThumbnailFillQueueTest.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeFilesPageModelTest.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/protocol/StaVideoDateTest.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/protocol/NativePreviewPolicy.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/protocol/NativePreviewPolicyTest.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/preview/ThumbnailCropPolicyTest.kt",
            "shared/src/iosMain/kotlin/com/ztransfer/preview/NativeThumbnailCropBridge.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/protocol/NativeStaDirectMetadata.kt",
            "shared/src/iosMain/kotlin/com/ztransfer/preview/NativeStaDirectBridge.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraCatalogScan.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/connection/NikonStaBridge.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/protocol/NativeStaDirectMetadataTest.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/catalog/NativeCameraCatalogScanTest.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/connection/NikonStaBridgeTest.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHomeText.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeConnectionHomeTest.kt"}
        allowed.update({workspace.ANDROID, workspace.COMMON, transition.ANDROID, transition.COMMON,
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeAppearanceModel.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalQueuePage.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativePhotoSettingsOverlay.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeDirectorySettingsModel.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeQueuePageModel.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeQueuePageModelTest.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeAppearanceModelTest.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeDirectorySettingsModelTest.kt",
            "shared/src/iosMain/kotlin/com/ztransfer/ui/NativeConnectionHomeController.kt",
            "shared/src/iosMain/kotlin/com/ztransfer/ui/SharedUiController.kt"})
        allowed.update({
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeBrowseSession.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeProductInformation.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeOriginalActionsTest.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalActions.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeRecoveryRecord.kt",
            "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeTransferMessages.kt",
            "shared/src/commonTest/kotlin/com/ztransfer/ui/NativeTransferMessagesTest.kt",
            "shared/src/iosMain/kotlin/com/ztransfer/ui/NativeGridImages.kt"})
        self.assertLessEqual(set(changes.splitlines()), allowed)


if __name__ == "__main__":
    unittest.main()
