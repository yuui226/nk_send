#!/usr/bin/env python3
"""Plan or explicitly create a local signed archive. NEVER export/upload or enable provisioning updates."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import uuid
from verify_on_mac import run_step, ROOT

def archive_arguments(team, bundle, output):
    if not re.fullmatch(r"[A-Z0-9]{10}", team or ""):
        raise ValueError("Provide your real 10-character Apple Team ID with --team or ZTRANSFER_APPLE_TEAM")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+){2,}", bundle or ""):
        raise ValueError("Invalid bundle identifier")
    output = Path(output).resolve()
    if not output.is_relative_to((ROOT / "iosApp" / "build" / "archives").resolve()):
        raise ValueError("Archive outputs must stay inside iosApp/build/archives")
    return ["xcodebuild", "-project", "iosApp/ZTransfer.xcodeproj", "-scheme", "ZTransfer",
            "-configuration", "Release", "-destination", "generic/platform=iOS",
            "-derivedDataPath", str(output / "DerivedData"), "-archivePath", str(output / "ZTransfer.xcarchive"),
            "DEVELOPMENT_TEAM=" + team, "PRODUCT_BUNDLE_IDENTIFIER=" + bundle, "CODE_SIGN_STYLE=Automatic", "archive"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", default=os.environ.get("ZTRANSFER_APPLE_TEAM"))
    parser.add_argument("--bundle-id", default="com.ztransfer.ios")
    parser.add_argument("--execute", action="store_true", help="Actually archive on Mac; omit to print the plan only")
    args = parser.parse_args()
    output = ROOT / "iosApp/build/archives" / (datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    try:
        command = archive_arguments(args.team, args.bundle_id, output)
        print(json.dumps({"command": command, "uploads": False, "mode": "execute" if args.execute else "plan"}, indent=2))
        if not args.execute:
            return 0
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise ValueError("Actual archive requires Apple-Silicon Mac and locally configured signing")
        env = os.environ.copy()
        env.pop("OVERRIDE_KOTLIN_BUILD_IDE_SUPPORTED", None)
        env["JAVA_HOME"] = subprocess.check_output(["/usr/libexec/java_home", "-v", "17"], text=True).strip()
        env["PATH"] = str(Path(env["JAVA_HOME"]) / "bin") + os.pathsep + env.get("PATH", "")
        output.mkdir(parents=True, exist_ok=False)
        run_step(command, output / "archive.log", env, "** ARCHIVE SUCCEEDED **")
        archive = output / "ZTransfer.xcarchive"
        if not (archive / "Info.plist").is_file() or not (archive / "dSYMs").is_dir():
            raise RuntimeError("Archive or dSYMs missing; do not distribute")
        print("Local archive only: " + str(archive) + "\nInspect signing, aggregated privacy report and dSYMs in Xcode before any separately authorized distribution.")
        return 0
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print("ARCHIVE BLOCKED: " + str(error))
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
