"""W41-W50 reviewed changes, preserving all preceding fixed source baselines."""
import hashlib
import subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
CHANGES = {
    "iosApp/ZTransfer.xcodeproj/project.pbxproj": "d9e56d49d05819e4085a643469fed4d7bdb766edad8f17934968f42c68b1e0b3",
    "iosApp/ZTransfer/Configuration/PrivacyInfo.xcprivacy": "731e9331c5f7600272d91f43c2b52b2fcbd2311b32d3a93e617013fe7dfbf31b",
    "iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift": "35ab75c62cab0169399b70e5e8e8592d97e4e0acaa7044a2c47189ba58a112ab",
    "iosApp/ZTransfer/Storage/TransferRecoveryJournal.swift": "0855108ce210a477418ed28dfd17dc6b4731b6a874f71fe95165750eb560ccfa",
    "iosApp/ZTransfer/UI/CameraWorkspace.swift": "e330baba42ee49866a8fd31ffbfba1a744f13c2a1b1cccf10a0df2afc397a53a",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt": "0b42e5f807be982310f973c2521ee43ec36ca8a8548ae96ac806fd1732deb364",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt": "bec7fa88f4424c871665f05585d5ca803ab653c9767c8c71ccfb446ad108fa2a",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativePhotoSettingsOverlay.kt": "de385c3553f6f31df51adf9edefb1b543d1a1874f43f680dc3cbd92433a9e00f",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeProductInformation.kt": "c31abdae55c16114c0d83ff302451a7cd65fa6d80f5908dd90cb6e17f08b7c5b",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeTransferMessages.kt": "b15dabc0b8233fd54e0926b673ef086e39b478ffd2982d9890f8fc1136a9a4f3"
}

def previous_final_completion_source(path, value):
    if path in CHANGES:
        assert hashlib.sha256(value.encode("utf8")).hexdigest() == CHANGES[path], f"reviewed final source changed: {path}"
        return subprocess.check_output(["git", "show", "f993e8e:" + path], cwd=ROOT).decode("utf8")
    return value
