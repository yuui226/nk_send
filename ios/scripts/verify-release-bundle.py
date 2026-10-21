#!/usr/bin/env python3
"""Read-only packaging checks; not signing, runtime, privacy-label or review approval."""
import argparse
import ipaddress
import json
import pathlib
import plistlib
import re
import sys
from urllib.parse import unquote, urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=pathlib.Path, help="Built Release .app bundle")
parser.add_argument("--submission", action="store_true",
                    help="Also fail if required legal URL configuration is missing or invalid; does not verify live pages or Apple acceptance")
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

# User-approved iOS scope: camera presets come only from the user's folder;
# bundled brand graphics were removed. Xcode can flatten resource groups, so
# check both the former directories and individual filenames at any depth.
removed_brand_logos = {
    f"{name}.svg" for name in (
        "nikon", "nikon-official", "apple", "dji", "fujifilm", "google", "honor",
        "huawei", "leica", "motorola", "nokia", "oneplus", "oppo", "panasonic",
        "samsung", "sony", "vivo", "xiaomi",
    )
}
removed_resources = []
for path in app.rglob("*"):
    if (path.suffix.lower() == ".np3" or path.name.lower() in removed_brand_logos
            or path.name.lower() in {"picturecontrols", "brandlogos", "picturecontrolfixtures"}):
        relative = str(path.relative_to(app))
        removed_resources.append(relative)
        errors.append(f"Removed camera preset/brand resource in Release: {relative}")
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

legal_urls = {key: info.get(key) for key in ("ZTransferPrivacyPolicyURL", "ZTransferTermsOfUseURL")}
legal_errors = []
for key, value in legal_urls.items():
    try:
        if not isinstance(value, str) or not value:
            raise ValueError("missing URL")
        decoded = unquote(value)
        if any(char.isspace() for char in decoded) or any(marker in decoded for marker in ("$(", "${", "【", "】", "<", ">", "***")):
            raise ValueError("URL contains whitespace or an unresolved placeholder")
        url = urlsplit(value)
        host = (url.hostname or "").lower().rstrip(".")
        if url.scheme != "https" or not host or url.username is not None or url.password is not None:
            raise ValueError("requires a public HTTPS URL without credentials")
        if url.port not in (None, 443):
            raise ValueError("requires the public HTTPS port")
        if ("." not in host or host.endswith((".localhost", ".local", ".test", ".invalid"))
                or any(host == domain or host.endswith("." + domain)
                       for domain in ("example.com", "example.org", "example.net"))):
            raise ValueError("local or example host is not a published policy site")
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            address = None
        if address is not None and not address.is_global:
            raise ValueError("private or reserved IP is not a public policy site")
    except ValueError as error:
        legal_errors.append(f"{key}: {error}")

passed = not errors and (not args.submission or not legal_errors)
report = {
    "bundle": str(app),
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "minimumOS": info.get("MinimumOSVersion"),
    "deviceFamilies": info.get("UIDeviceFamily"),
    "packagingChecksPassed": not errors,
    "errors": errors,
    "removedCameraPresetsAndBrandLogosAbsent": not removed_resources,
    "removedCameraPresetAndBrandLogoResources": removed_resources,
    "validationMode": "packaging-and-submission-configuration" if args.submission else "packaging",
    "selectedChecksPassed": passed,
    "legalURLs": legal_urls,
    "legalURLConfigurationPassed": not legal_errors,
    "legalURLConfigurationErrors": legal_errors,
    "notCovered": [
        "Code signing, device Archive validation and App Store upload",
        "Live legal URLs, policy content, in-app link reachability and all submission metadata",
        "Runtime behavior, permissions, hardware, UI and real Apple sandbox",
        "Complete data-flow, encryption classification and intellectual-property review",
    ],
}
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if passed else 1)
