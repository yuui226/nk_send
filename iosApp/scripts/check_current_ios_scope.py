"""Current-branch Windows scope gate.

The historical extraction guards intentionally keep their old checkpoints. This small gate
checks the current handoff invariants without weakening those guards or treating Apple runtime
verification as complete.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ANDROID_PATHS = (
    "app", "shared/src/androidMain", "dist", "dist-debug", "gradle",
    "build.gradle.kts", "settings.gradle.kts", "gradle.properties",
    "shared/build.gradle.kts",
)
IOS_EFFECT_FILES = (
    "iosApp/ZTransfer/Storage/PhotoEffectsBatchCoordinator.swift",
    "iosApp/ZTransfer/Storage/PhotoEffectsBatchSession.swift",
    "iosApp/ZTransfer/Storage/PhotoEffectsExportService.swift",
    "iosApp/ZTransfer/Storage/PhotoEffectsPicker.swift",
    "iosApp/ZTransfer/Storage/PhotoEffectsPreviewStore.swift",
    "iosApp/ZTransfer/Storage/PhotoFilterCatalogStore.swift",
    "iosApp/ZTransfer/UI/PhotoEffectsPresentation.swift",
    "iosApp/ZTransfer/UI/PhotoEffectsWorkbench.swift",
    "shared/src/commonMain/kotlin/com/ztransfer/frame/NativePhotoFrameBridge.kt",
    "shared/src/commonTest/kotlin/com/ztransfer/frame/NativePhotoFrameBridgeTest.kt",
)


def changed_android_paths(base: str = "master") -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...HEAD", "--", *ANDROID_PATHS],
        cwd=ROOT, check=True, capture_output=True, text=True, encoding="utf-8",
    )
    return [line for line in result.stdout.splitlines() if line]


def verify() -> None:
    changed = changed_android_paths()
    if changed:
        raise AssertionError("Android/build scope changed relative to master: " + ", ".join(changed))
    missing = [path for path in IOS_EFFECT_FILES if not (ROOT / path).is_file()]
    if missing:
        raise AssertionError("Missing iOS effect production files: " + ", ".join(missing))
    workbench = (ROOT / "iosApp/ZTransfer/UI/PhotoEffectsWorkbench.swift").read_text(encoding="utf-8")
    presentation = (ROOT / "iosApp/ZTransfer/UI/PhotoEffectsPresentation.swift").read_text(encoding="utf-8")
    if workbench.count("PhotoEffectsPreviewPager") != 1:
        raise AssertionError("Photo-effects preview owner is not unique")
    if presentation.count("PhotoEffectsWorkbench") != 1:
        raise AssertionError("Photo-effects presentation does not have one workbench owner")
    exporter = (ROOT / "iosApp/ZTransfer/Storage/PhotoEffectsExportService.swift").read_text(encoding="utf-8")
    if exporter.count("throw PhotoEffectsExportError.unsupportedFilter") != 1:
        raise AssertionError("Unsupported filters are not reported separately from invalid sources")
    if exporter.index("throw PhotoEffectsExportError.invalidSource") > exporter.index("throw PhotoEffectsExportError.unsupportedFilter"):
        raise AssertionError("Source validation must happen before filter validation")
    for token in (
        "catalog.id(index: selection.index) == selection.filterID",
        "catalog.catalogKey(index: selection.index) == selection.catalogKey",
    ):
        if token not in exporter:
            raise AssertionError("Filter selection identity is not validated before export: " + token)
    print("PASS Android/build scope unchanged relative to master")
    print("PASS iOS photo-effects production files, frame bridge and single presentation owner are present")
    print("NOTE Apple Swift compilation, shared bridge export names, frame/watermark rendering and device behavior remain unverified")


if __name__ == "__main__":
    verify()
