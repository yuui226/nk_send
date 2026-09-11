"""W31-W40 reviewed changes; keep all earlier behavior/extraction baselines intact."""
import hashlib
import subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
CHANGES = {
    "iosApp/ZTransfer.xcodeproj/project.pbxproj": "161e21bd491f8ff4f39dcf041c1639aaccb325ba8ebe4de64208e01d656721cf",
    "iosApp/ZTransfer/Configuration/OriginalDestinationPreferences.swift": "dc1eab73c9b2697d80835eaf41f07c76a6d62af514d65213f4c9566c923358f7",
    "iosApp/ZTransfer/ContentView.swift": "03d99e7a9621e6684b411f1e5871f5ba08b1faa1a8a84eeac26c4b029ab222ba",
    "iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift": "c8dfb89054e0a53e8bc5b242e420bdbe4de5f571b78c689237084d3951df754d",
    "iosApp/ZTransfer/Network/CameraBonjourDiscovery.swift": "ae587041391b0a5856d692b611babbda6a0754dc2dc9f11e1c49bf90be05ba09",
    "iosApp/ZTransfer/Network/CameraDiscoveryCoordinator.swift": "7b603677361a9d1931bc482eeaa9c0c6ae4adaa2fc9691c219f9104f080af8cd",
    "iosApp/ZTransfer/Network/CameraOriginalQueue.swift": "22191d5ccf50d577c049a627a69a15ee6e47eaf3b3523117a66e6e68f4ff5638",
    "iosApp/ZTransfer/Network/CameraPreviewStore.swift": "72c86bfb2b1d779e1f7978a57c5acb3a74a22775f4c91d6048dce2bc1cbc32bb",
    "iosApp/ZTransfer/Network/CameraWiFiConnection.swift": "ff4a195988ac845728f146bf2b2bb3610403063af5fb332ea3c65cc14e4e59dc",
    "iosApp/ZTransfer/Network/PtpIPChannel.swift": "d1573b700a5c80d1330dfc3c34591a22708aca554572b568aadbf3a7cd3dde21",
    "iosApp/ZTransfer/Network/PtpIPCommandSession.swift": "edd5210d8281269df8c87ee9d177736ea859726cb7b7743ddc6b30fc2ce2c9a1",
    "iosApp/ZTransfer/UI/CameraWorkspace.swift": "ad79fea152bb2612a3a64a81c5b80dbdef0cbad009c0e7042791dc80290954f3",
    "iosApp/ZTransfer/UI/OriginalFilesPage.swift": "cb6259d8af0f9ef1b8aea25a75392a254020ea977069346b94ecc9baf8399e76",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt": "fcc8a757b2386e05445980123a25e065d7c340531a2b009a5dc237e957f9d3c9",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt": "db077a742e78dd045822d8266237f11963a84bb249f4c7d7178f278273207e28",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalActions.kt": "04ebeae2c0d6e40ca1441c006952d8db73e0bd4dec8a7923915b70eb8ed01dcf",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt": "13e80bd9f2cd75f9837fdb43960d4d6bb6407804f6ed215b3e82fa3410052ad6",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalQueuePage.kt": "bee5f5067cc3a18c119e358be4deb1d2243e0e1e64442162b88ece245fb690ab",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativePhotoSettingsOverlay.kt": "642585cd57367d0cf7f17bb2bffc97f0eaa93bec64ab824217c34a75ae14247d",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeQueuePageModel.kt": "053cfc86d820ee9cf3ae3523527b93ba0ec6609c915fab490eb864386f392a5e",
    "shared/src/iosMain/kotlin/com/ztransfer/ui/NativeGridImages.kt": "47049dc0a5183e9505dca186267e2edc40117e54f95b35a0d8b62523f12c2105",
    "shared/src/iosMain/kotlin/com/ztransfer/ui/SharedUiController.kt": "47e7199502609e90d7eab9a5fa71237c48fd481b41ed95ea20726d726e79949e"
}

def previous_lifecycle_completion_source(path, value):
    from final_completion_wiring import previous_final_completion_source
    value = previous_final_completion_source(path, value)
    if path in CHANGES:
        assert hashlib.sha256(value.encode("utf8")).hexdigest() == CHANGES[path], f"reviewed lifecycle source changed: {path}"
        return subprocess.check_output(["git", "show", "8594187:" + path], cwd=ROOT).decode("utf8")
    return value
