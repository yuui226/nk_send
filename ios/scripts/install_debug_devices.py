#!/usr/bin/env python3
"""Install a signed Debug app on reachable, paired iOS devices (USB or Wi-Fi).

Xcode 27's devicectl JSON v5 includes simulators and introduces `properties`.
Older Xcode schemas remain supported. A disconnected tunnel may be opened by
install; `unavailable` is an offline device and must not be selected automatically.
"""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


@dataclass(frozen=True)
class Device:
    identifier: str
    name: str
    transport: str
    legacy: bool = False


def select_devices(core, xcdevices, requested=""):
    selected = []
    seen = set()
    known = set()

    def add(device, aliases):
        if requested and requested not in aliases:
            return
        if device.identifier not in seen:
            selected.append(device)
            seen.add(device.identifier)

    for entry in core:
        properties = entry.get("properties", {})
        hardware = {**entry.get("hardwareProperties", {}), **properties.get("hardware", {})}
        connection = {**entry.get("connectionProperties", {}), **properties.get("connection", {})}
        state = {**entry.get("deviceProperties", {}), **properties.get("state", {})}
        identifier = hardware.get("udid") or entry.get("identifier")
        aliases = {value for value in (identifier, entry.get("identifier"), state.get("name")) if value}
        aliases.update(connection.get("potentialHostnames", []))
        known.update(aliases)
        transport = connection.get("transportType", "unknown")
        simulator = (hardware.get("reality") == "simulated" or transport == "sameMachine"
                     or entry.get("visibilityClass") == "simulators"
                     or state.get("visibilityClass") == "simulators"
                     or "Simulator" in state.get("provider", ""))
        if (not identifier or simulator or hardware.get("platform") != "iOS"
                or connection.get("pairingState") != "paired"
                or connection.get("state", connection.get("tunnelState")) == "unavailable"):
            continue
        add(Device(identifier, state.get("name", identifier), transport,
                   connection.get("isMobileDeviceOnly", False)), aliases)

    for entry in xcdevices:
        identifier = entry.get("identifier")
        previously_known = identifier in known
        aliases = {value for value in (identifier, entry.get("name")) if value}
        known.update(aliases)
        # CoreDevice is authoritative for known devices, including offline ones.
        if (not identifier or previously_known or entry.get("simulator")
                or entry.get("ignored") or not entry.get("available")
                or entry.get("platform") != "com.apple.platform.iphoneos"):
            continue
        version = re.match(r"\d+", entry.get("operatingSystemVersion", ""))
        legacy = bool(version and int(version.group()) < 17)
        add(Device(identifier, entry.get("name", identifier), entry.get("interface", "unknown"), legacy),
            aliases)

    if requested and not selected:
        if requested in known:
            raise ValueError("Requested device is not an available paired physical iOS device: " + requested)
        # devicectl also accepts a hostname/name even if discovery has not listed it.
        selected.append(Device(requested, requested, "explicit"))
    return selected


def discover_devices(requested=""):
    core, xcdevices = [], []
    successful_queries = 0
    with tempfile.TemporaryDirectory(prefix="ztransfer-devices-") as directory:
        core_path = Path(directory) / "devices.json"
        try:
            subprocess.run(["xcrun", "devicectl", "list", "devices", "--timeout", "15",
                            "--json-output", str(core_path)], check=True, capture_output=True,
                           text=True, timeout=20)
            values = json.loads(core_path.read_text())["result"]["devices"]
            if not isinstance(values, list) or not all(isinstance(value, dict) for value in values):
                raise ValueError("Invalid devicectl devices list")
            core = values
            successful_queries += 1
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
            print("WARNING: CoreDevice discovery failed: " + str(error), file=sys.stderr)
        try:
            result = subprocess.run(["xcrun", "xcdevice", "list", "--timeout", "5"],
                                    check=True, capture_output=True, text=True, timeout=20)
            values = json.loads(result.stdout)
            if not isinstance(values, list) or not all(isinstance(value, dict) for value in values):
                raise ValueError("Invalid xcdevice devices list")
            xcdevices = values
            successful_queries += 1
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            print("WARNING: xcdevice discovery failed: " + str(error), file=sys.stderr)
    if not successful_queries and not requested:
        raise RuntimeError("Device discovery failed; cannot determine whether an iPhone is connected.")
    return select_devices(core, xcdevices, requested)


def install_device(device, app, bundle_id):
    if not device.legacy:
        subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device",
                        device.identifier, str(app), "--timeout", "120"], check=True, timeout=130)
        subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device",
                        device.identifier, "--terminate-existing", "--timeout", "60", bundle_id],
                       check=True, timeout=70)
        return

    # Older iOS uses MobileDevice. Do not disable Wi-Fi with --no-wifi.
    subprocess.run(["ios-deploy", "--id", device.identifier, "--bundle", str(app),
                    "--nostart", "--timeout", "10"], check=True, timeout=130)
    launch = ["idevicedebug", "-u", device.identifier]
    if device.transport in ("network", "wireless", "wifi"):
        launch.append("--network")
    subprocess.run(launch + ["--detach", "run", bundle_id], check=True, timeout=70)
    time.sleep(2)
    result = subprocess.run(["ios-deploy", "--id", device.identifier, "--get_pid",
                             "--bundle_id", bundle_id, "--timeout", "10"],
                            check=True, capture_output=True, text=True, timeout=20)
    if not re.search(r"pid:\s*[1-9][0-9]*", result.stdout + result.stderr):
        raise RuntimeError("App installed, but no running process was found after launch.")


def install_devices(devices, app, bundle_id):
    if not devices:
        print("No available paired iOS device found; skipping physical-device installation.")
        return 0
    failed = 0
    for device in devices:
        print(f"Installing and launching on {device.name} ({device.identifier}, {device.transport})...", flush=True)
        try:
            install_device(device, app, bundle_id)
            print(f"Installed and launched on {device.name} ({device.identifier}).", flush=True)
        except (OSError, subprocess.SubprocessError, RuntimeError) as error:
            failed += 1
            print(f"ERROR: {device.name} ({device.identifier}): {error}", file=sys.stderr, flush=True)
    print(f"Physical-device installation: {len(devices) - failed} succeeded, {failed} failed.", flush=True)
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--bundle-id", default="com.ztransfer.ios")
    parser.add_argument("--device", default="")
    parser.add_argument("--list-only", action="store_true", help="Discover targets without installing or launching")
    args = parser.parse_args()
    if not args.app.is_dir() or args.app.suffix != ".app":
        parser.error("--app must point to an existing signed .app bundle")
    try:
        devices = discover_devices(args.device)
        if args.list_only:
            for device in devices:
                print(f"{device.identifier}\t{device.name}\t{device.transport}")
            return 0
        return install_devices(devices, args.app.resolve(), args.bundle_id)
    except (RuntimeError, ValueError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
