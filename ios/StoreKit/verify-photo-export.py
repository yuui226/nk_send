#!/usr/bin/env python3
"""Read-only checks of original Photos files on a dedicated test simulator.

The UI test uses the real picker, authorization prompt, and production save.
This verifier does not create assets or repair output. It retains new JPEGs as
test evidence and checks that no existing original was modified or removed.
"""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def inventory(root):
    return {
        str(path.relative_to(root)): {
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
        for path in sorted(root.rglob("*")) if path.is_file()
    }


def originals_root(device_id):
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "--json"], text=True
    ))["devices"]
    device = next(item for group in devices.values() for item in group
                  if item["udid"] == device_id)
    if not device["name"].startswith("ZTransfer-"):
        raise ValueError("Photo export tests require a dedicated ZTransfer-* simulator")
    return Path(device["dataPath"]) / "Media" / "DCIM"


def snapshot(device_id, destination):
    root = originals_root(device_id)
    if not root.is_dir():
        raise ValueError("No Photos originals directory; add the fixture before snapshotting")
    data = {"device": device_id, "originalsRoot": str(root), "files": inventory(root)}
    Path(destination).write_text(json.dumps(data, indent=2))


def verify(snapshot_path, expected):
    snapshot_path = Path(snapshot_path)
    before = json.loads(snapshot_path.read_text())
    root = Path(before["originalsRoot"])
    after = inventory(root)
    for name, original in before["files"].items():
        if after.get(name) != original:
            raise AssertionError(f"An existing original changed or disappeared: {name}")
    added = sorted(set(after) - set(before["files"]))
    if len(added) != expected:
        raise AssertionError(f"Expected {expected} new original(s), found {added}")
    evidence = snapshot_path.with_suffix("")
    evidence.mkdir(exist_ok=True)
    outputs = []
    for name in added:
        source = root / name
        if source.read_bytes()[:2] != b"\xff\xd8":
            raise AssertionError(f"Generated output is not JPEG: {name}")
        target = evidence / source.name
        shutil.copyfile(source, target)
        dimensions = subprocess.check_output(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)], text=True
        )
        if "<nil>" in dimensions:
            raise AssertionError(f"Unreadable output dimensions: {name}")
        outputs.append({"file": str(target), **after[name], "dimensions": dimensions.strip()})
    result = {"unchangedOriginals": len(before["files"]), "newOriginals": outputs}
    evidence.with_suffix(".verified.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "check":
        originals_root(sys.argv[2])
        raise SystemExit(0)
    if len(sys.argv) != 4 or sys.argv[1] not in {"snapshot", "verify"}:
        raise SystemExit("Usage: verify-photo-export.py check SIMULATOR_ID | snapshot SIMULATOR_ID FILE | verify FILE COUNT")
    if sys.argv[1] == "snapshot":
        snapshot(sys.argv[2], sys.argv[3])
    else:
        verify(sys.argv[2], int(sys.argv[3]))
