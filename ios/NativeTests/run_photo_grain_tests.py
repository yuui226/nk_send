"""Run the unchanged Android grain oracle and the iOS RGBA adapter on macOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="ztransfer-grain-") as folder:
    for name, sources in (
        ("android-oracle", [root / "NativeTests/photo_grain_android_oracle.cpp"]),
        ("rgba-bridge", [root / "NativeTests/photo_grain_bridge.cpp", root / "ThirdParty/PhotoGrain/PhotoGrainBridge.cpp"]),
    ):
        binary = Path(folder) / name
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-ffp-contract=off", "-fno-fast-math", "-fwrapv",
                        "-I", str(root / "ThirdParty/PhotoGrain"), *map(str, sources), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
