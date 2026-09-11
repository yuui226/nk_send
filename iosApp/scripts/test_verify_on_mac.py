"""Windows-safe tests of preflight selection only; no Apple tools or builds are run."""
import unittest
from unittest.mock import patch, MagicMock

from verify_on_mac import choose_simulator, preflight, run_step


class MacVerificationTests(unittest.TestCase):
    def device(self, suffix, **changes):
        return dict({"name": "iPhone Test", "udid": f"00000000-0000-0000-0000-{suffix:012d}",
                     "isAvailable": True, "state": "Shutdown"}, **changes)

    def test_selects_latest_available_phone_and_excludes_other_devices(self):
        older, newer = self.device(1), self.device(2)
        inventory = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-16-0": [older],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [newer, self.device(3, isAvailable=False), self.device(4, name="iPad")],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-0": [self.device(5)],
        }}
        self.assertEqual(choose_simulator(inventory), newer)
        self.assertEqual(choose_simulator(inventory, older["udid"]), older)

    def test_prefers_already_booted_supported_phone(self):
        booted = self.device(1, state="Booted")
        inventory = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-17-0": [booted],
                                 "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [self.device(2)]}}
        self.assertEqual(choose_simulator(inventory), booted)

    def test_uses_type_identifier_for_renamed_phone(self):
        phone = self.device(1, name="My test phone", deviceTypeIdentifier="com.apple.CoreSimulator.SimDeviceType.iPhone-16")
        self.assertEqual(choose_simulator({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [phone]}}), phone)

    def test_missing_unavailable_old_or_unknown_requested_device_is_rejected(self):
        for inventory in [{}, {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-15-0": [self.device(1)]}},
                          {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [self.device(1, isAvailable=False)]}}]:
            with self.assertRaises(ValueError):
                choose_simulator(inventory)
        with self.assertRaises(ValueError):
            choose_simulator({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [self.device(1)]}}, self.device(2)["udid"])

    def test_windows_preflight_stops_before_any_external_command(self):
        with patch("verify_on_mac.platform.system", return_value="Windows"), patch("verify_on_mac.capture") as command:
            with self.assertRaises(RuntimeError):
                preflight()
            command.assert_not_called()

    def test_zero_exit_without_build_success_marker_is_not_pass(self):
        process = MagicMock()
        process.stdout = ["Nothing actually built\n"]
        process.wait.return_value = 0
        with patch("verify_on_mac.subprocess.Popen", return_value=process), patch("builtins.print"):
            with self.assertRaisesRegex(RuntimeError, "Missing success marker"):
                run_step(["fake-build"], MagicMock(), {}, "BUILD SUCCESSFUL")

    def test_build_requires_both_success_marker_and_zero_exit(self):
        process = MagicMock()
        process.stdout = ["BUILD SUCCESSFUL in 1s\n"]
        process.wait.return_value = 1
        with patch("verify_on_mac.subprocess.Popen", return_value=process), patch("builtins.print"):
            with self.assertRaisesRegex(RuntimeError, "exit 1"):
                run_step(["fake-build"], MagicMock(), {}, "BUILD SUCCESSFUL")
            process.wait.return_value = 0
            run_step(["fake-build"], MagicMock(), {}, "BUILD SUCCESSFUL")


if __name__ == "__main__":
    unittest.main()
