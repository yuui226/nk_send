"""W21-W30 fixed full-file fingerprints before the W11-W20 historical inverse chain."""
import hashlib
import subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
CHANGES = {
    "iosApp/ZTransfer/Configuration/AppAppearanceSettings.swift": "abccc46edde2e3bb86079ef09c87680a1f5315a936074882bca4384f7a3ff76b",
    "iosApp/ZTransfer/Configuration/BrowsePreferencesStore.swift": "11dcfcde3ecf603cfd0eaf299558b066227d0491655678b2e9ea3b1dc8e74ddf",
    "iosApp/ZTransfer/Configuration/OriginalDestinationPreferences.swift": "0f62b3d062b05b11a319162ed500a5b83e9eff3951102d424f9d70735bd1c70f",
    "iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift": "9ecef13d1368c532634d66e0eb799459761265912c7ca2098d0d7680d9d3997a",
    "iosApp/ZTransfer/Network/CameraOriginalQueue.swift": "75865d341c6d166d595c2ad65e96e65d861b4fe5648ba4f570e298ec24e68ffd",
    "iosApp/ZTransfer/Storage/OriginalFilesReading.swift": "5bf00db5a4e542404195a19879b7b74efdee4caae79dc74e32e2208124a35061",
    "iosApp/ZTransfer/UI/CameraWorkspace.swift": "25d8d9f2ba896f732e166d9934946a64cc353b73537a0800ea40f31bb05c44aa",
    "iosApp/ZTransfer/UI/OriginalFilesPage.swift": "09e7c156415b801b87fa043be7b473965a664cf1627f3d87a475ce107ee66175",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeAppearanceModel.kt": "948c2b470de7693b507d7fc2ad40cdc2bf52bddebdf472fa5abdf913a89f2413",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt": "3fb78f108435c8eaa8ff619777fe9fa14dbf10af5ff7afc2880e319fe1a0c281",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHomeText.kt": "4a56be077c57e8bd05f8b1f4302aa2797b4b8452246179dd5f27a8999db7d8ef",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeDirectorySettingsModel.kt": "3b06282b515a3c6a1b6fc4144f9b95bf5eee0f57518198b80ca2401f06f715ff",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt": "6245fd7ce67c83db41cd064ec1e4a0e38f9d1f346aba4708c9e44f173e3e8bd9",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt": "6e4552c932612d7f2f556da3fcc6eb8979ef86591bb26bfe52a2d679d9eb625e",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalQueuePage.kt": "50bb53a86d7f762ed84aac6b3991e4e263f1c49216cdcfd3f341a331f8b4ecc9",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativePhotoSettingsOverlay.kt": "5ec7894b1b12007471f9cd00b592cae589b4a9784378d021697475619af76429",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeQueuePageModel.kt": "1331e81a248401d02e5d60156c7f57583b55caa4059432df2fe6c2429b9de0fa",
    "shared/src/iosMain/kotlin/com/ztransfer/ui/NativeConnectionHomeController.kt": "1fdda76c032556dc6d359d29880d04c5fd69ebdbaba2293d417a1b872b5a28ce",
    "shared/src/iosMain/kotlin/com/ztransfer/ui/SharedUiController.kt": "1fde63ea0f80351b25eedf725d7e7672022c09a8a62286a24b48b22b66557fcb"
}

def previous_workspace_completion_source(path, value):
    from queue_workspace_extraction import previous_queue_workspace_source
    from workspace_transition_extraction import previous_workspace_transition_source
    value = previous_queue_workspace_source(path, value)
    value = previous_workspace_transition_source(path, value)
    if path in CHANGES:
        assert hashlib.sha256(value.encode("utf8")).hexdigest() == CHANGES[path], f"reviewed workspace completion source changed: {path}"
        return subprocess.check_output(["git", "show", "ad101d5:" + path], cwd=ROOT).decode("utf8")
    return value
