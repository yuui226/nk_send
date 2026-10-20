#!/usr/bin/env python3
"""Read-only packaging checks; not signing, runtime, privacy-label or review approval."""
import argparse
import json
import pathlib
import plistlib
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=pathlib.Path, help="Built Release .app bundle")
args = parser.parse_args()
app = args.app.resolve()
ios = pathlib.Path(__file__).resolve().parents[1]
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def plist(path):
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        errors.append(f"Cannot read {path.name}: {error}")
        return {}


info = plist(app / "Info.plist")
require(info.get("CFBundleIdentifier") == "com.ztransfer.ios", "Unexpected bundle identifier")
require(info.get("MinimumOSVersion") == "16.0", "Minimum OS differs from current release plan")
require(set(info.get("UIDeviceFamily", [])) == {1, 2}, "Expected iPhone and iPad device families")
require(bool(info.get("CFBundleShortVersionString")), "Missing version")
require(bool(info.get("CFBundleVersion")), "Missing build number")

manifest = plist(app / "PrivacyInfo.xcprivacy")
source_manifest = plist(ios / "ZTransfer/Resources/PrivacyInfo.xcprivacy")
require(bool(manifest) and manifest == source_manifest, "Packaged privacy manifest differs from source")
for source_notice in sorted((ios / "ZTransfer/Resources/licenses").glob("*.txt")):
    notice = app / source_notice.name
    require(notice.is_file() and notice.read_bytes() == source_notice.read_bytes(),
            f"Missing or outdated third-party notice: {source_notice.name}")

for name in ("great_vibes_regular.ttf", "bebas_neue_regular.ttf", "cormorant_garamond_medium_italic.ttf"):
    target = app / name
    source = ios / "ZTransfer/Resources/Fonts" / name
    require(target.is_file() and target.read_bytes() == source.read_bytes(), f"Missing or changed font: {name}")

for path in app.rglob("*"):
    if (path.name in {"debug_sample_01.jpg", "debug_sample_fhd.jpg", "__preview.dylib"}
            or path.name.endswith(".debug.dylib") or path.suffix in {".storekit", ".xctest"}):
        errors.append(f"Test-only resource in Release: {path.relative_to(app)}")

executable = app / info.get("CFBundleExecutable", "ZTransfer")
if executable.is_file():
    binary = executable.read_bytes()
    launch_source = (ios / "ZTransfer/App/ZTransferApp.swift").read_text()
    flags = sorted(set(re.findall(r'"(--[^"]*test)"', launch_source)))
    for token in ["App-Prefs:", "--trace-storekit-startup", *flags]:
        require(token.encode() not in binary, f"Debug/private route string remains: {token}")
else:
    errors.append("Missing executable")

report = {
    "bundle": str(app),
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "minimumOS": info.get("MinimumOSVersion"),
    "deviceFamilies": info.get("UIDeviceFamily"),
    "packagingChecksPassed": not errors,
    "errors": errors,
    "legalURLs": {
        key: info.get(key) for key in ("ZTransferPrivacyPolicyURL", "ZTransferTermsOfUseURL")
    },
    "notCovered": [
        "Code signing, device Archive validation and App Store upload",
        "Live legal URLs and all submission metadata",
        "Runtime behavior, permissions, hardware, UI and real Apple sandbox",
        "Complete data-flow, encryption classification and intellectual-property review",
    ],
}
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if not errors else 1)
