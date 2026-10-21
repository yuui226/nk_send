#!/usr/bin/env python3
"""Exercise release-resource rejection with synthetic bundles; never builds an app."""
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


IOS = pathlib.Path(__file__).resolve().parents[1]


class RemovedAssetPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ztransfer-packaging-test-")
        self.addCleanup(self.temporary.cleanup)
        self.app = pathlib.Path(self.temporary.name) / "Synthetic.app"
        self.app.mkdir()
        info = {
            "CFBundleIdentifier": "com.ztransfer.ios", "MinimumOSVersion": "16.0",
            "UIDeviceFamily": [1, 2], "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1", "CFBundleExecutable": "Synthetic",
            "ZTransferPrivacyPolicyURL": "https://www.ztransfer.top/ios/privacy/",
            "ZTransferTermsOfUseURL": "https://www.ztransfer.top/ios/terms/",
        }
        (self.app / "Info.plist").write_bytes(plistlib.dumps(info))
        # Not an executable or release candidate; only inputs to a static check.
        (self.app / "Synthetic").write_bytes(b"Synthetic packaging fixture")
        resources = IOS / "ZTransfer/Resources"
        for source in [resources / "PrivacyInfo.xcprivacy",
                       *sorted((resources / "licenses").glob("*.txt")),
                       *sorted((resources / "Fonts").glob("*.ttf"))]:
            shutil.copyfile(source, self.app / source.name)

    def check(self):
        result = subprocess.run([sys.executable, str(IOS / "scripts/verify-release-bundle.py"),
                                 str(self.app), "--submission"], capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.returncode, json.loads(result.stdout)

    def testCleanBundleAndUnrelatedUserWatermarkRemainAllowed(self):
        (self.app / "watermark.png").write_bytes(b"unrelated image resource")
        code, report = self.check()
        self.assertEqual(code, 0, report)
        self.assertTrue(report["removedCameraPresetsAndBrandLogosAbsent"])

    def testNP3DocumentsAreRejectedAtAnyDepthIgnoringExtensionCase(self):
        for name in ("Unknown.np3", "Nested/Imported.NP3", "Nested/Mixed.Np3"):
            with self.subTest(name=name):
                resource = self.app / name
                resource.parent.mkdir(parents=True, exist_ok=True)
                resource.write_bytes(b"synthetic preset")
                try:
                    code, report = self.check()
                    self.assertEqual(code, 1, report)
                    self.assertIn(name, report["removedCameraPresetAndBrandLogoResources"])
                finally:
                    resource.unlink()

    def testFlattenedFormerBrandGraphicsAreRejected(self):
        names = ("nikon", "nikon-official", "apple", "dji", "fujifilm", "google",
                 "honor", "huawei", "leica", "motorola", "nokia", "oneplus",
                 "oppo", "panasonic", "samsung", "sony", "vivo", "xiaomi")
        for name in names:
            with self.subTest(name=name):
                resource = self.app / (name + ".svg")
                resource.write_text("<svg/>")
                try:
                    code, report = self.check()
                    self.assertEqual(code, 1, report)
                    self.assertIn(resource.name, report["removedCameraPresetAndBrandLogoResources"])
                finally:
                    resource.unlink()

    def testFormerAssetAndTestFixtureDirectoriesAreRejected(self):
        for name in ("PictureControls", "BrandLogos", "PictureControlFixtures"):
            with self.subTest(name=name):
                resource = self.app / name
                resource.mkdir()
                try:
                    code, report = self.check()
                    self.assertEqual(code, 1, report)
                    self.assertIn(name, report["removedCameraPresetAndBrandLogoResources"])
                finally:
                    resource.rmdir()


if __name__ == "__main__":
    unittest.main()
