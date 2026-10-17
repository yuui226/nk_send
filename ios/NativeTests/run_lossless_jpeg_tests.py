"""Run production crop bridge fault tests on macOS with ASan and UBSan."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
# Use the app's exact codec source list, avoiding an independently configured
# system JPEG library or a duplicate list that can silently drift.
sources = re.findall(r"- path: (ThirdParty/libjpeg-8bit/src/[^\n]+\.c)", (root / "project.yml").read_text())
assert sources
with tempfile.TemporaryDirectory(prefix="ztransfer-native-crop-build-") as build:
    binary = Path(build) / "crop-tests"
    subprocess.run(["xcrun", "clang", "-O1", "-g", "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer", "-I", str(root / "ThirdParty/libjpeg-8bit/src"),
                    str(root / "NativeTests/LosslessJpegBridgeTests.c"),
                    *(str(root / source) for source in sources), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
