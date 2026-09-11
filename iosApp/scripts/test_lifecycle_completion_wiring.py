"""W31-W40 current contracts. Source guards are NOT Swift/Native execution."""
import hashlib
from pathlib import Path
import subprocess
import unittest
import lifecycle_completion_wiring as reviewed
ROOT = Path(__file__).resolve().parents[2]
def read(path): return (ROOT / path).read_text(encoding="utf8")
S = "iosApp/ZTransfer/"
U = "shared/src/commonMain/kotlin/com/ztransfer/ui/"

class LifecycleCompletionTest(unittest.TestCase):
    def test_reviewed_inverse_and_mutation_rejection(self):
        self.assertGreaterEqual(len(reviewed.CHANGES), 22)
        for path in reviewed.CHANGES:
            with self.subTest(path=path):
                source = read(path)
                baseline = subprocess.check_output(["git", "show", "8594187:" + path], cwd=ROOT).decode("utf8")
                self.assertEqual(reviewed.previous_lifecycle_completion_source(path, source), baseline)
                with self.assertRaises(AssertionError):
                    reviewed.previous_lifecycle_completion_source(path, source + "\n// mutation\n")

    def test_android_hosts_protocol_and_build_inputs_unchanged(self):
        paths = ["app", "platform", "dist", "dist-debug", "gradle", "build.gradle.kts",
                 "settings.gradle.kts", "shared/src/androidMain"]
        self.assertEqual(subprocess.check_output(["git", "diff", "8594187", "--name-only", "--"] + paths,
                         cwd=ROOT).decode().strip(), "")

    def test_cancel_recovery_retains_transaction_gate_and_shared_wire(self):
        value = read(S + "Network/PtpIPCommandSession.swift")
        for token in ("defer { release() }", "try await operation.value", "recovery.request(CancellationError())",
                      "recovery.arm()", "await recovery.finish()", "32 * 1024 * 1024",
                      "3_000_000_000", "drained", "connectionPoisoned", "discarded"):
            self.assertIn(token, value)
        self.assertIn("encodeCancelRequest", read(S + "Network/PtpIPChannel.swift"))
        tests = read("iosApp/ZTransferTests/CameraNetworkTests.swift")
        for name in ("testStreamingSinkFailureDrainsBeforeReusingCommandGate",
                     "testStreamingCancellationHoldsGateUntilMatchingResponseIsDrained",
                     "testStreamingCancelledWithoutResponseClosesWithinRecoveryBudget"):
            self.assertIn(name, tests)

    def test_finite_background_lease_and_fresh_foreground_action(self):
        source = read(S + "UI/CameraWorkspace.swift")
        foreground = source.split("func enterForeground()", 1)[1].split("func close()", 1)[0]
        self.assertNotIn("connectProduct(", foreground)
        self.assertNotIn("startQueue(", foreground)
        for token in ("beginBackgroundTask(", "endBackgroundTask(", "generation == token",
                      "if !backgroundLease.isActive", "forceAbortForBackgroundExpiration()"):
            self.assertIn(token, source)
        probe = read(S + "Diagnostics/CameraHandshakeProbe.swift")
        self.assertEqual(probe.count("for await snapshot in queue.updates"), 1)
        self.assertIn('guard apConnection === connection, productState?.phase != "closing"', probe)

    def test_recovery_is_bounded_explanatory_and_never_old_handle_resume(self):
        source = read(S + "Storage/TransferRecoveryJournal.swift")
        for token in ("512 * 1024", "pending.prefix(500)", "historyRevision > 0",
                      "snapshot.connectionID == activeConnection", "options: .atomic",
                      "activeConnection = nil", "recoveryBackup-", ".typeRegular"):
            self.assertIn(token, source)
        for token in ("downloadOriginal(", "append(", "handle:", "removeItem("):
            self.assertNotIn(token, source)
        tests = read("iosApp/ZTransferTests/CameraWorkspaceTests.swift")
        for token in ("testRecoveryJournalFencesGenerationAndDoesNotPersistByteTicks",
                      "testRecoveryJournalPreservesUnknownCorruptAndOversizedRecords",
                      "testRecoveryJournalBoundsPendingRowsWithoutClaimingResume",
                      "testFailureCodesDistinguishPermissionTimeoutCancellationAndStorageWithoutPaths"):
            self.assertIn(token, tests)

    def test_memory_pressure_drops_images_not_queue_or_catalog(self):
        probe = read(S + "Diagnostics/CameraHandshakeProbe.swift")
        body = probe.split("func releasePreviewMemory()", 1)[1].split("func refreshCatalog()", 1)[0]
        self.assertIn("filesPage?.model.releaseImageMemory()", body)
        self.assertIn("queuePage?.model.releaseImageMemory()", body)
        self.assertNotIn("queue.stop", body)
        images = read("shared/src/iosMain/kotlin/com/ztransfer/ui/NativeGridImages.kt")
        self.assertIn("memoryEpoch", images)
        self.assertIn("releaseMemory()", images)
        self.assertIn("mutableMemoryRevision.value++", read(U + "NativeQueuePageModel.kt"))

    def test_transfer_permissions_localizations_and_no_deferred_prompt(self):
        project = read("iosApp/ZTransfer.xcodeproj/project.pbxproj")
        for key in ("NSBluetoothAlwaysUsageDescription", "NSLocationWhenInUseUsageDescription",
                    "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription"):
            self.assertNotIn(key, project)
        for locale in ("en", "zh-Hans", "zh-Hant"):
            source = read(S + "Configuration/" + locale + ".lproj/InfoPlist.strings")
            self.assertEqual(source.count('"NSLocalNetworkUsageDescription"'), 1)
            self.assertEqual(source.count('"NSPhotoLibraryAddUsageDescription"'), 1)
            self.assertIn(locale + ".lproj/InfoPlist.strings", project)
        entry = read(S + "ContentView.swift")
        self.assertNotIn("LocationProbeView()", entry); self.assertNotIn("BluetoothProbeView()", entry)
        self.assertIn("UIApplication.openSettingsURLString", read(S + "UI/OriginalFilesPage.swift"))

    def test_layout_accessibility_and_language_bind_to_real_pages(self):
        for file in ("NativeConnectionHome.kt", "NativeOriginalFilesPage.kt"):
            self.assertIn("safeDrawingPadding()", read(U + file))
        self.assertIn("imePadding()", read(U + "NativeConnectionHome.kt"))
        self.assertIn("FlowRow(", read(U + "NativeOriginalFilesPage.kt"))
        actions = read(U + "NativeOriginalActions.kt")
        self.assertIn("LiveRegionMode.Polite", actions)
        self.assertIn("contentDescription", actions)
        self.assertIn("NativeTransferMessages.render", read(U + "NativeOriginalQueuePage.kt"))
        mapping = read(S + "Storage/TransferFailureMessage.swift")
        self.assertIn("NSFileWriteOutOfSpaceError", mapping)
        self.assertNotIn("localizedDescription", mapping)
        self.assertNotIn("ns.userInfo", mapping)

if __name__ == "__main__": unittest.main()
