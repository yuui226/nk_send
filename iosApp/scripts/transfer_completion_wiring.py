"""W11-W20 reviewed full-file fingerprints (LF/UTF-8) before historical inverse guards.
A byte change anywhere fails closed. The Git baseline is read only AFTER matching the
reviewed current fingerprint. Behavior tests and current wiring contracts are separate.
This replaces growing copies of full Swift hunks, not the whole-file comparison.
"""
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CHANGES = {
    "iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift": "45a8d4e0914d56a49f2f4261a3762b29383c34da2d9d8580fd2a2217765f130c",
    "iosApp/ZTransfer/Network/CameraCatalog.swift": "62687c22d80084d41d7efaad0a37dc9c3f5915766e33a74ce66d2f59e38298c5",
    "iosApp/ZTransfer/Network/CameraPreviewStore.swift": "eaa1463292d472c81349444b6e881f7bbeb2d68d9783b5d303afce503a03c6bc",
    "iosApp/ZTransfer/Network/CameraWiFiConnection.swift": "fe2bd53d4d85f6fb59241f78bae456ab947a83ab9a3bbad7d9fb2b61b97f5217",
    "iosApp/ZTransfer/Network/StationProfileStore.swift": "4d4702e2bf73f6eb1476646f917868b15d1fb1e6ffee88fab14085dc83790086",
    "iosApp/ZTransfer/Storage/IndexedOriginalReader.swift": "4f46d5968965bdcd6c85d41d9929bdedf344f46b47cb1f06314fa0175cbc801e",
    "iosApp/ZTransfer/Storage/PreviewImageDecoder.swift": "b4bda443fe1a7591219a8631843d950164014d485549adf68023047005cecfb4",
    "iosApp/ZTransfer/UI/CameraWorkspace.swift": "b24216d3d33f13d928a484b9b84b302a177dffd2ec70142a78b196a38876d2e7",
    "iosApp/ZTransfer/UI/OriginalFilesPage.swift": "c5f648abbcabaadb66dd63ba631a115a656a49d1cda0f9a49bf4cbcc82af8dff",
    "iosApp/ZTransfer/UI/OriginalQueuePage.swift": "84df91c1380a966221b610cb3792adf52b7b633ae7d18a4cbc4cacb5be638013",
    "shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraCatalogScan.kt": "0a4cfd17af7ae2a25e0fbca5fc18c3411b5cac757bc156302f38e26e54fc5a26",
    "shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeThumbnailFillQueue.kt": "235444ba141e2f4c0744ffa44ebaa11925cc4c4e19bfbd0a4ced0dbc5f860a49",
    "shared/src/commonMain/kotlin/com/ztransfer/catalog/ThumbnailFillQueue.kt": "581714aee246237a9a8a162fc31cf054ac4056f357065249c8186fbe8863570f",
    "shared/src/commonMain/kotlin/com/ztransfer/connection/NikonStaBridge.kt": "7474aaaf61da02f41761de0049df3dc3e2f30f77c8bc2819fbd61b452a70c56a",
    "shared/src/commonMain/kotlin/com/ztransfer/preview/PreviewExifRationalReader.kt": "b1fb11f6519f2521b537626dd812ca5179040e91d1286c156cfcf6546c14d7ec",
    "shared/src/commonMain/kotlin/com/ztransfer/preview/PreviewExifSupplement.kt": "bba1c586f8dbdc7084cf92c39153ad104b08697d1a23caf71a7c9cf62ae36a11",
    "shared/src/commonMain/kotlin/com/ztransfer/protocol/NativePreviewPolicy.kt": "944b56970cb5814367e5eb1e2e7390208084b5182fb4b4861ad0fc7c0bb7aff4",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt": "1efade3420de289618258c965df6fef57fad7f52d736f0ab6b4d5ba9f2ed2f8c",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHomeText.kt": "4252a1fe9b5bdfced579217c8177017012aca18b4be30e65f79daaaae9cc37a0",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt": "fe05607d666af4e83408f6d8a3f793a895548b4cc7d6470e2ed79fb30fe10020",
    "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedConnectionMethodCard.kt": "7424954497fbbc7282b2c2c0da999cc6c022d3d1484655bb7bc50766bc9d3e21"
}

def previous_transfer_completion_source(path, value):
    from sta_media_extraction import previous_sta_media_source
    from thumbnail_crop_extraction import previous_thumbnail_crop_source
    value = previous_sta_media_source(path, value)
    value = previous_thumbnail_crop_source(path, value)
    if path in CHANGES:
        assert hashlib.sha256(value.encode("utf8")).hexdigest() == CHANGES[path], f"reviewed transfer completion source changed: {path}"
        return subprocess.check_output(["git", "show", "e5dbadb:" + path], cwd=ROOT).decode("utf8")
    return value
