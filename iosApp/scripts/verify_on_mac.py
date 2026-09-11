#!/usr/bin/env python3
"""Sequential Apple-Silicon acceptance. Never signs/uploads an app or changes project settings."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]


def choose_simulator(inventory, requested=None):
    candidates = []
    for runtime, devices in inventory.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+)(?:-(\d+))?", runtime)
        if not match or int(match[1]) < 16:
            continue
        version = (int(match[1]), int(match[2] or 0))
        for device in devices:
            kind = device.get("deviceTypeIdentifier", "")
            is_phone = ".iPhone-" in kind if kind else device.get("name", "").startswith("iPhone")
            if not device.get("isAvailable", False) or not is_phone:
                continue
            try:
                identifier = str(uuid.UUID(device["udid"]))
            except (KeyError, ValueError, AttributeError):
                continue
            candidates.append((device.get("state") == "Booted", version, identifier, device))
    if requested:
        normalized = str(uuid.UUID(requested))
        candidates = [item for item in candidates if item[2] == normalized]
    if not candidates:
        raise ValueError("No matching available iPhone simulator (iOS 16+). Install an iOS runtime in Xcode.")
    return max(candidates, key=lambda item: item[:3])[3]


def capture(arguments, env=None):
    result = subprocess.run(arguments, cwd=ROOT, env=env, text=True, encoding="utf-8",
                            errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return result.stdout.strip()


def preflight(requested=None):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("Requires a native Apple-Silicon Mac with Xcode; Windows cannot validate Swift/iOS.")
    env = os.environ.copy()
    # A framework bypass from an IDE must not turn this verification into a stale-framework test.
    env.pop("OVERRIDE_KOTLIN_BUILD_IDE_SUPPORTED", None)
    env["JAVA_HOME"] = capture(["/usr/libexec/java_home", "-v", "17"])
    env["PATH"] = str(Path(env["JAVA_HOME"]) / "bin") + os.pathsep + env.get("PATH", "")
    xcode = capture(["xcodebuild", "-version"], env)
    capture(["xcrun", "--find", "swift"], env)
    local = ROOT / "local.properties"
    sdk = None
    if local.is_file():
        match = re.search(r"^\s*sdk\.dir\s*=\s*(.+)$", local.read_text(encoding="utf-8"), re.M)
        if match:
            sdk = match[1].strip().replace("\\:", ":").replace("\\ ", " ")
    sdk = sdk or env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT")
    if not sdk or not (Path(sdk) / "platforms" / "android-35" / "android.jar").is_file():
        raise RuntimeError("Configure this Mac's Android SDK 35 in local.properties or ANDROID_HOME; do not copy the Windows SDK path.")
    inventory = json.loads(capture(["xcrun", "simctl", "list", "devices", "available", "--json"], env))
    device = choose_simulator(inventory, requested)
    print(f"Xcode: {xcode}\nSimulator: {device['name']} ({device['udid']})", flush=True)
    return env, device, xcode


def run_step(arguments, log_path, env, required_marker=None):
    print(f"Running: {' '.join(arguments)}\nLog: {log_path}", flush=True)
    marker_seen = required_marker is None
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(arguments, cwd=ROOT, env=env, text=True, encoding="utf-8",
                                   errors="replace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            for line in process.stdout:
                if required_marker and required_marker in line:
                    marker_seen = True
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
            code = process.wait()
        except BaseException:
            # Only the process group created for this step; never stop unrelated user builds.
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise
    if code != 0:
        raise RuntimeError(f"Step failed (exit {code}); see {log_path}")
    if not marker_seen:
        raise RuntimeError(f"Missing success marker {required_marker!r}; see {log_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", help="Optional existing iPhone simulator UUID; otherwise select an available one")
    parser.add_argument("--preflight-only", action="store_true", help="Check tools/SDK/simulator without building")
    args = parser.parse_args()
    try:
        env, device, xcode = preflight(args.simulator)
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"PREFLIGHT BLOCKED: {error}", file=sys.stderr)
        return 2
    if args.preflight_only:
        print("Preflight passed. No Swift build or XCTest has been run.")
        return 0

    output = ROOT / "iosApp" / "build" / "verification" / (datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    output.mkdir(parents=True, exist_ok=False)
    project = ["xcodebuild", "-project", "iosApp/ZTransfer.xcodeproj", "-scheme", "ZTransfer",
               "-derivedDataPath", str(output / "DerivedData"), "CODE_SIGNING_ALLOWED=NO"]
    steps = [
        ("structure", [sys.executable, "iosApp/scripts/check_structure.py"], "PASS Xcode references"),
        ("native-tests", ["/bin/sh", "./gradlew", ":shared:iosSimulatorArm64Test", "--no-daemon", "--console=plain"], "BUILD SUCCESSFUL"),
        ("swift-tests", project + ["-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={device['udid']}",
                                   "-parallel-testing-enabled", "NO", "-resultBundlePath", str(output / "Tests.xcresult"), "test"], "** TEST SUCCEEDED **"),
        ("release-device-build", project + ["-configuration", "Release", "-destination", "generic/platform=iOS", "build"], "** BUILD SUCCEEDED **"),
        ("debug-device-build", project + ["-configuration", "Debug", "-destination", "generic/platform=iOS", "build"], "** BUILD SUCCEEDED **"),
        ("release-simulator-build", project + ["-configuration", "Release", "-destination", f"platform=iOS Simulator,id={device['udid']}", "build"], "** BUILD SUCCEEDED **"),
    ]
    report = {"status": "RUNNING", "xcode": xcode, "simulator": device["udid"], "steps": [],
              "commit": capture(["git", "rev-parse", "HEAD"], env),
              "working_tree_dirty": bool(capture(["git", "status", "--porcelain"], env)),
              "scope": "Native tests, Swift tests and unsigned Release compilation. NOT camera/device acceptance or distribution."}
    try:
        for name, arguments, marker in steps:
            report["steps"].append({"name": name, "status": "RUNNING"})
            run_step(arguments, output / f"{name}.log", env, marker)
            report["steps"][-1]["status"] = "PASS"
        report["status"] = "PASS"
    except (RuntimeError, OSError, KeyboardInterrupt) as error:
        report["status"] = "FAILED"
        report["steps"][-1]["status"] = "FAILED"
        report["error"] = str(error) or "Interrupted"
        print(report["error"], file=sys.stderr)
    finally:
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{report['status']}: {output}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
