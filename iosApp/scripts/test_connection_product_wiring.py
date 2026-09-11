"""Connection product source checks; Apple tests remain Mac-only."""
from pathlib import Path
import re
import subprocess
import unittest
import home_card_extraction as home
from connection_product_wiring import CHANGES, previous_connection_product_source

ROOT = Path(__file__).resolve().parents[2]

class ConnectionProductWiringTest(unittest.TestCase):
    def test_actual_apple_path_not_internet_probe_controls_permission_and_route(self):
        source = (ROOT / "iosApp/ZTransfer/Network/CameraTCPStream.swift").read_text(encoding="utf-8")
        self.assertIn("parameters.requiredInterfaceType = .wifi", source)
        self.assertIn("parameters.requiredInterface = interface", source)
        self.assertIn("path.status == .satisfied", source)
        self.assertIn("path.usesInterfaceType(.wifi)", source)
        self.assertIn("self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied", source)
        self.assertIn("connection.pathUpdateHandler = nil", source)
        self.assertNotIn("NWPathMonitor(", source)
        self.assertNotIn("http://", source)

    def test_numeric_endpoint_history_is_gated_by_real_ready_identity_after_awaits(self):
        source = (ROOT / "iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift").read_text(encoding="utf-8")
        block = source.split("let resolvedHost = await connection.resolvedRemoteHost()", 1)[1].split("sessionReady = true", 1)[0]
        self.assertLess(block.index("try Task.checkCancellation()"), block.index("try Self.recordVerifiedStationEndpoint"))
        self.assertLess(block.index("historyState.phase == .ready"), block.index("try Self.recordVerifiedStationEndpoint"))
        self.assertIn("apConnection === connection", block)
        self.assertIn("resolvedHost: resolvedHost", block)
        self.assertIn("let address = service == nil ? host : resolvedHost", source)

    def test_discovery_and_profile_recovery_do_not_start_fallback_network_or_infer_trust(self):
        source = (ROOT / "iosApp/ZTransfer/Network/CameraDiscoveryCoordinator.swift").read_text(encoding="utf-8")
        self.assertIn("CameraEndpointHistory.applicationDiscoveryStore()", source)
        selection = source.split("func selectProfile(", 1)[1].split("func forgetProfile(", 1)[0]
        self.assertNotIn("start()", selection)
        self.assertIn("expectedResponderGUID: entry.responderGUID", selection)
        deletion = source.split("func forgetProfile(", 1)[1].split("@discardableResult", 1)[0]
        self.assertLess(deletion.index("profileStore.forgetResponder"), deletion.index("history.forget"))
        self.assertIn("reloadProfiles() // A failed metadata write", deletion)
        store = (ROOT / "iosApp/ZTransfer/Network/StationProfileStore.swift").read_text(encoding="utf-8")
        self.assertIn("type.isSymbolicLink != true", store)
        self.assertIn("document.version == 1", store)

    def test_entire_original_card_and_android_calls_are_preserved(self):
        home.verify()
        body = (ROOT / home.COMMON).read_text(encoding="utf-8")
        self.assertNotIn("android.", body)
        self.assertNotIn("SystemClock", body)
        self.assertIn("uptimeMillis()", body)

    def test_reviewed_connection_deltas_restore_full_checkpoint_files(self):
        for path in CHANGES:
            before = subprocess.check_output(["git", "show", "6ab3302:" + path], cwd=ROOT).decode()
            self.assertEqual(before, previous_connection_product_source(path, (ROOT / path).read_text(encoding="utf-8")))

    def test_shared_home_uses_original_card_and_has_traditional_copy_for_every_label(self):
        page = (ROOT / "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt").read_text(encoding="utf-8")
        text = (ROOT / "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHomeText.kt").read_text(encoding="utf-8")
        self.assertIn("SharedConnectionMethodCard(", page)
        self.assertIn("WifiModeTabs(", page)
        self.assertNotIn("FilterChip(", page)
        for chinese in re.findall(r'label\("([^"]+)", "', page):
            self.assertIn('"' + chinese + '" to ', text, chinese)

    def test_mode_preference_never_stores_pairing_or_session_authority(self):
        source = (ROOT / "iosApp/ZTransfer/UI/CameraWorkspace.swift").read_text(encoding="utf-8")
        body = source.split("@MainActor final class CameraConnectionPreferences", 1)[1].split("private struct CameraWorkspaceController", 1)[0]
        self.assertIn("let version: Int; let mode: String", body)
        self.assertIn('guard read() != nil, ["ap", "sta"].contains(mode)', body)
        self.assertNotIn("allowPairing", body)
        self.assertNotIn("pairedResponders", body)

if __name__ == "__main__":
    unittest.main()
