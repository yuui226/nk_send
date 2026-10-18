"""Device-discovery regressions; no Xcode build or real device mutations."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import install_debug_devices as installer


def core_device(identifier, reality="physical", transport="wired", state="disconnected", paired=True):
    return {
        "identifier": "core-" + identifier,
        "properties": {
            "hardware": {"platform": "iOS", "reality": reality, "udid": identifier},
            "connection": {"pairingState": "paired" if paired else "unpaired",
                           "state": state, "transportType": transport},
            "state": {"name": identifier},
        },
    }


def xc_device(identifier, version="27.0", interface="usb", available=True):
    return {"identifier": identifier, "name": identifier, "simulator": False,
            "platform": "com.apple.platform.iphoneos", "operatingSystemVersion": version,
            "interface": interface, "available": available}


class DeviceInstallationTests(unittest.TestCase):
    def test_simulators_first_do_not_hide_usb_or_wifi_devices(self):
        # Regression: Xcode 27 returns paired iOS simulators before real phones.
        entries = [core_device("sim", "simulated", "sameMachine"), core_device("usb"),
                   core_device("wifi", transport="localNetwork"),
                   core_device("offline", state="unavailable"), core_device("unpaired", paired=False)]
        self.assertEqual([d.identifier for d in installer.select_devices(entries, [])], ["usb", "wifi"])

    def test_legacy_json_supports_wifi_without_an_open_tunnel(self):
        entries = [{"identifier": "old-core", "hardwareProperties": {"platform": "iOS", "udid": "wifi"},
                    "deviceProperties": {"name": "Phone"}, "connectionProperties": {
                        "pairingState": "paired", "tunnelState": "disconnected", "transportType": "localNetwork"}}]
        self.assertEqual(installer.select_devices(entries, [])[0].identifier, "wifi")

    def test_deduplicates_sources_and_does_not_resurrect_offline_core_device(self):
        core = [core_device("usb"), core_device("offline", state="unavailable")]
        xc = [xc_device("usb"), xc_device("offline"), xc_device("additional", interface="network")]
        self.assertEqual([d.identifier for d in installer.select_devices(core, xc)], ["usb", "additional"])

    def test_explicit_core_id_selects_only_requested_phone(self):
        self.assertEqual([d.identifier for d in installer.select_devices(
            [core_device("first"), core_device("second")], [], "core-second")], ["second"])

    def test_explicit_simulator_or_offline_phone_is_rejected(self):
        for entry in (core_device("target", reality="simulated"), core_device("target", state="unavailable")):
            with self.assertRaises(ValueError):
                installer.select_devices([entry], [], "target")
        with self.assertRaises(ValueError):
            installer.select_devices([], [xc_device("target", available=False)], "target")

    def test_xcdevice_fallback_selects_modern_and_legacy_transports(self):
        entries = [xc_device("modern", interface="network"), xc_device("old", "16.7", "network")]
        devices = installer.select_devices([], entries)
        self.assertEqual([(d.identifier, d.legacy) for d in devices], [("modern", False), ("old", True)])

    def test_install_failure_does_not_prevent_next_device_installation(self):
        devices = [installer.Device("first", "First", "wired"), installer.Device("second", "Second", "localNetwork")]
        with patch.object(installer.subprocess, "run") as run, redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            run.side_effect = [subprocess.CalledProcessError(1, "install"), None, None]
            self.assertEqual(installer.install_devices(devices, Path("App with spaces.app"), "bundle"), 1)
        self.assertEqual(run.call_count, 3)
        calls = [call.args[0] for call in run.call_args_list]
        self.assertIn("second", calls[1])
        self.assertIn("second", calls[2])
        self.assertEqual(calls[2][2:4], ["device", "process"])

    def test_launch_timeout_does_not_prevent_next_device(self):
        devices = [installer.Device("first", "First", "wired"), installer.Device("second", "Second", "localNetwork")]
        with patch.object(installer.subprocess, "run") as run, redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            run.side_effect = [None, subprocess.TimeoutExpired("launch", 70), None, None]
            self.assertEqual(installer.install_devices(devices, Path("App.app"), "bundle"), 1)
        self.assertEqual(run.call_count, 4)

    def test_legacy_network_install_does_not_disable_wifi(self):
        device = installer.Device("old", "Old Phone", "network", True)
        with patch.object(installer.subprocess, "run") as run, patch.object(installer.time, "sleep"):
            run.return_value = subprocess.CompletedProcess([], 0, stdout="pid: 123", stderr="")
            installer.install_device(device, Path("App.app"), "bundle")
        self.assertNotIn("--no-wifi", run.call_args_list[0].args[0])
        self.assertIn("--network", run.call_args_list[1].args[0])

    def test_empty_devices_skip_without_install_commands(self):
        with patch.object(installer.subprocess, "run") as run, redirect_stdout(io.StringIO()):
            self.assertEqual(installer.install_devices([], Path("App.app"), "bundle"), 0)
        run.assert_not_called()

    def test_discovery_failure_is_not_reported_as_no_connected_phone(self):
        with patch.object(installer.subprocess, "run", side_effect=subprocess.TimeoutExpired("list", 20)), redirect_stderr(io.StringIO()):
            with self.assertRaises(RuntimeError):
                installer.discover_devices()

    def test_core_discovery_failure_can_use_xcdevice(self):
        with patch.object(installer.subprocess, "run") as run, redirect_stderr(io.StringIO()):
            run.side_effect = [subprocess.CalledProcessError(1, "list"),
                               subprocess.CompletedProcess([], 0, stdout=json.dumps([xc_device("wifi", interface="network")]))]
            self.assertEqual(installer.discover_devices()[0].identifier, "wifi")


if __name__ == "__main__":
    unittest.main()
