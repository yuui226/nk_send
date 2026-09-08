"""W21-W30 current wiring and mutation guards; no claim of Apple runtime execution."""
from pathlib import Path
import subprocess
import unittest
import workspace_completion_wiring as reviewed
import queue_workspace_extraction as capsule
import workspace_transition_extraction as transition

ROOT = Path(__file__).resolve().parents[2]
def read(path):
    return (ROOT / path).read_text(encoding="utf8")

class WorkspaceCompletionWiringTest(unittest.TestCase):
    def test_every_reviewed_file_matches_and_rejects_unrelated_mutation(self):
        self.assertGreaterEqual(len(reviewed.CHANGES), 19)
        for path in reviewed.CHANGES:
            with self.subTest(path=path):
                source = read(path)
                baseline = subprocess.check_output(["git", "show", "ad101d5:" + path], cwd=ROOT).decode("utf8")
                self.assertEqual(reviewed.previous_workspace_completion_source(path, source), baseline)
                with self.assertRaises(AssertionError):
                    reviewed.previous_workspace_completion_source(path, source + "\n// unrelated mutation\n")

    def test_entire_android_and_shared_ui_extractions_are_exact(self):
        for extraction in (capsule, transition):
            extraction.verify()
            path = extraction.ANDROID
            source = read(path)
            with self.assertRaises(AssertionError):
                reviewed.previous_workspace_completion_source(path, source + "\n// changed owner\n")
        changed = subprocess.check_output(["git", "diff", "ad101d5", "--name-only", "--",
            "app", "platform", "dist", "dist-debug", "build.gradle.kts", "settings.gradle.kts",
            "gradle", "shared/src/androidMain"], cwd=ROOT).decode().splitlines()
        self.assertEqual(set(changed), {capsule.ANDROID, transition.ANDROID})

    def test_actual_queue_receipts_drive_both_manual_and_automatic_flights(self):
        source = read("shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt")
        for token in ("SharedQueuePill(", "SharedFilesQueueWorkspace(", "QueueFlightGhost(",
                      "if (model.enqueue(files) == files.size)", "LaunchedEffect(arrivals.revision)",
                      "heldCount = flights.filter", "cachedThumbnail(files.first())",
                      "onQueueFlightCaught"):
            self.assertIn(token, source)
        probe = read("iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift")
        self.assertEqual(probe.count("for await snapshot in queue.updates"), 1)
        self.assertIn("expectAutomaticArrival", probe)
        page = read("iosApp/ZTransfer/UI/OriginalFilesPage.swift")
        self.assertIn("observeQueuePublication", page)
        self.assertIn("rememberBrowseSession?(model.captureBrowseSession())", page)

    def test_saved_actions_copy_indexed_original_bytes_and_never_camera_handles(self):
        source = read("iosApp/ZTransfer/UI/OriginalFilesPage.swift").split("final class OriginalActionPresenter", 1)[1]
        for token in ("item.originalName", "item.originalSize", "item.locator", "try await importer.save(saved.url)",
                      "UIActivityViewController(activityItems: urls", "forExporting: urls, asCopy: true",
                      "completionWithItemsHandler", "Set(urls).count == urls.count",
                      "complete ? preparedIndices : []", "sourceRect = CGRect", "Task.isCancelled"):
            self.assertIn(token, source)
        for token in ("downloadOriginal", "removeItem(", "deleteObject", "PHAsset.fetch"):
            self.assertNotIn(token, source)
        copies = read("iosApp/ZTransfer/Storage/OriginalFilesReading.swift").split("actor OriginalActionCopies", 1)[1]
        for token in ("source.copyOriginal", "SandboxTransferFile", "Task.checkCancellation()", "release()"):
            self.assertIn(token, copies)

    def test_preference_repairs_preserve_each_domains_backup(self):
        for path in ("Configuration/BrowsePreferencesStore.swift", "Configuration/AppAppearanceSettings.swift",
                     "Configuration/OriginalDestinationPreferences.swift", "UI/CameraWorkspace.swift"):
            source = read("iosApp/ZTransfer/" + path)
            self.assertIn(".recoveryBackup", source)
            self.assertNotIn("removePersistentDomain", source)
        home = read("shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt")
        self.assertIn("resetModeConfirmed", home)

    def test_new_apple_scenarios_remain_registered(self):
        tests = read("iosApp/ZTransferTests/CameraNetworkTests.swift")
        for token in ("testBrowseSessionSurvivesPageReplacementButRejectsAnotherConnection",
                      "OriginalActionReceipt", "OriginalActionCopies", "OriginalActionPresenter",
                      "didPickDocumentsAt:", "recoveryBackup"):
            self.assertIn(token, tests)
        self.assertIn("testExplicitConnectionModeRepairBacksUpUnknownBytesAndKeepsOtherDomains",
            read("iosApp/ZTransferTests/CameraWorkspaceTests.swift"))
        project = read("iosApp/ZTransfer.xcodeproj/project.pbxproj")
        self.assertIn("CameraNetworkTests.swift in Sources", project)
        from check_structure import OpenStepParser
        objects = OpenStepParser(project).parse()["objects"]
        target = next(v for v in objects.values() if v.get("isa") == "PBXNativeTarget" and v.get("name") == "ZTransferTests")
        refs = [objects[objects[file]["fileRef"]]["path"]
                for phase in target["buildPhases"] if objects[phase]["isa"] == "PBXSourcesBuildPhase"
                for file in objects[phase]["files"]]
        self.assertEqual(refs.count("CameraWorkspaceTests.swift"), 1)

if __name__ == "__main__":
    unittest.main()
