"""Source-equivalence guard for the first Android -> shared UI batch; not a screenshot test."""
from pathlib import Path
import argparse
import difflib
import re
import subprocess
from transfer_card_extraction import extract_transfer_cards
from transfer_page_extraction import extract_transfer_page, extract_collapse_height
from signal_pill_extraction import extract_signal_pill
from queue_execution_extraction import extract_queue_execution
from thumbnail_grid_extraction import extract_thumbnail_grid
from filter_overlay_extraction import extract_filter_overlay, extract_anchor_popup, expected_contract
from export_exit_extraction import extract_export_exit
from photo_viewport_extraction import extract_photo_viewport
from photo_preview_model_extraction import extract_photo_preview_model
from photo_preview_display_extraction import extract_photo_preview_display
from histogram_extraction import extract_histogram, extract_histogram_button
from photo_preview_session_extraction import extract_photo_preview_session, extract_queue_flight

FILES = (
    "theme/Type.kt", "theme/Motion.kt", "theme/Color.kt", "screen/ZMark.kt", "screen/BroomMark.kt",
    "screen/Marks.kt", "screen/TransferStatusIcons.kt", "screen/ControlTileFieldLabel.kt",
    "screen/TransferProgressMotion.kt", "screen/LiquidProgressFill.kt",
    "screen/GlassButton.kt", "screen/ConnectionCardMaterial.kt", "theme/SkinTexture.kt",
    "screen/ReleaseCommitWheel.kt", "screen/TipLightbulbButton.kt", "screen/Fireworks.kt",
    "screen/WatermarkPlacementPreference.kt",
)
RESOURCE_ENUM = """enum class SkinPreset(val displayNameResId: Int) {
    FROSTED_GLASS(R.string.skin_frosted_glass),
    TITANIUM(R.string.skin_titanium),
    WOOD(R.string.skin_wood),
    CAMERA_CONTROLS(R.string.skin_camera_controls),"""
SHARED_ENUM = """enum class SkinPreset {
    FROSTED_GLASS,
    TITANIUM,
    WOOD,
    CAMERA_CONTROLS,"""


def expected_shared(source, path):
    source = source.replace("\r\n", "\n")
    if path == "theme/Color.kt":
        if source.count(RESOURCE_ENUM) != 1:
            raise ValueError("Unexpected original SkinPreset; review the migration baseline")
        source = source.replace("import com.ztransfer.R\n", "").replace(RESOURCE_ENUM, SHARED_ENUM)
    if path in ("screen/ControlTileFieldLabel.kt", "screen/TransferProgressMotion.kt", "screen/LiquidProgressFill.kt", "screen/GlassButton.kt"):
        source = source.replace("internal fun ", "fun ")
    if path == "screen/ConnectionCardMaterial.kt":
        source = source.replace("internal fun ", "fun ").replace("internal data class ", "data class ").replace("internal const val ", "const val ")
    if path == "theme/SkinTexture.kt":
        source = source.replace("import android.graphics.Bitmap\n", "").replace("import androidx.compose.ui.graphics.asImageBitmap\n", "")
        source = source.replace("internal val skin: SkinPreset", "val skin: SkinPreset")
        source = source.replace("Math.floorMod(", "textureFloorMod(")
        source = source.replace("private val tileCacheLock = Any()", "private val tileCacheLock = TextureCacheLock()")
        source = source.replace("synchronized(tileCacheLock)", "tileCacheLock.withLock")
        source = source.replace("Bitmap.createBitmap(pixels, TILE, TILE, Bitmap.Config.ARGB_8888)\n                .asImageBitmap()",
                                "createTextureImageBitmap(pixels, TILE, TILE)")
    if path in ("screen/ReleaseCommitWheel.kt", "screen/WatermarkPlacementPreference.kt", "screen/TipLightbulbButton.kt"):
        source = source.replace("internal fun ", "fun ").replace("internal data class ", "data class ")
    return source


def expected_android_haptics(source):
    source = source[:source.index("const val PROGRESSIVE_HOLD_HAPTIC_DURATION_MS")].rstrip() + "\n"
    source = source.replace("class Haptics(private val view: View, private val enabled: Boolean) {",
                            "private class AndroidHaptics(private val view: View, private val enabled: Boolean) : Haptics {")
    for method in ("tick", "longPress", "success", "failure", "startProgressiveHold", "cancelProgressiveHold", "completeProgressiveHold"):
        source = source.replace(f"    fun {method}()", f"    override fun {method}()")
    return source.replace("fun rememberHaptics(enabled: Boolean)", "actual fun rememberHaptics(enabled: Boolean)").replace(
        "remember(view, enabled) { Haptics(view, enabled) }", "remember(view, enabled) { AndroidHaptics(view, enabled) }")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-ref", default="55876fa")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]

    def original(relative):
        return subprocess.run(["git", "show", f"{args.base_ref}:{relative}"], cwd=root,
                              check=True, capture_output=True, text=True, encoding="utf-8").stdout

    for path in FILES:
        old = f"app/src/main/java/com/ztransfer/ui/{path}"
        new = root / f"shared/src/commonMain/kotlin/com/ztransfer/ui/{path}"
        if (root / old).exists():
            raise ValueError(f"Duplicate Android implementation remains: {old}")
        expected = expected_shared(original(old), path)
        actual = new.read_text(encoding="utf-8")
        if actual != expected:
            diff = "".join(difflib.unified_diff(expected.splitlines(True), actual.splitlines(True),
                                                fromfile="baseline + approved mechanical edits", tofile=str(new)))
            raise ValueError(diff)
        print(f"PASS unchanged UI body: {path}")
    old_theme = original("app/src/main/java/com/ztransfer/ui/theme/Theme.kt")
    new_theme = (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/theme/SharedTheme.kt").read_text(encoding="utf-8")
    # Every explicitly configured Material color and both light/dark branches must be preserved.
    def schemes(text):
        return text[text.index("private val DarkColorScheme"):text.index("@Composable")]
    if schemes(old_theme) != schemes(new_theme):
        raise ValueError("Material color schemes changed during theme extraction")
    print("PASS original Material color schemes; Android window/texture adapter still needs runtime verification")
    old_transfer = original("app/src/main/java/com/ztransfer/ui/screen/TransferScreen.kt")
    new_transfer = (root / "app/src/main/java/com/ztransfer/ui/screen/TransferScreen.kt").read_text(encoding="utf-8")
    expected_transfer = old_transfer.replace(".animateItemPlacement(Motion.itemPlacement)",
        ".animateItem(\n                                fadeInSpec = null,\n"
        "                                placementSpec = Motion.itemPlacement,\n                                fadeOutSpec = null,\n                            )")
    expected_transfer, expected_cards = extract_transfer_cards(expected_transfer)
    expected_transfer, expected_page = extract_transfer_page(expected_transfer)
    if new_transfer != expected_transfer:
        raise ValueError("Transfer screen differs beyond the approved placement API and presentation extraction")
    actual_cards = (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/TransferCardComponents.kt").read_text(encoding="utf-8")
    if actual_cards != expected_cards:
        raise ValueError("Shared transfer rendering differs beyond explicit localized-text parameters/visibility changes")
    actual_page = (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedTransferScreen.kt").read_text(encoding="utf-8")
    if actual_page != expected_page:
        raise ValueError("Shared queue page differs beyond explicit service/clock/text/slot substitutions")
    file_list_path = "app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt"
    expected_list, expected_collapse = extract_collapse_height(original(file_list_path))
    expected_list, expected_signal = extract_signal_pill(expected_list)
    expected_list, expected_execution = extract_queue_execution(expected_list)
    expected_list, expected_grid = extract_thumbnail_grid(expected_list)
    expected_list, expected_filter = extract_filter_overlay(expected_list)
    expected_list, expected_export_exit = extract_export_exit(expected_list)
    expected_list, expected_flight = extract_queue_flight(expected_list)
    if (root / 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/QueueFlightCurve.kt').read_text(encoding='utf-8') != expected_flight:
        raise ValueError('Original shared queue flight curve/easing differs')
    if (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/ExportExitUiState.kt").read_text(encoding="utf-8") != expected_export_exit:
        raise ValueError("Original untransferred completion-exit state/callback differs")
    expected_popup_android, expected_popup = extract_anchor_popup(original("app/src/main/java/com/ztransfer/ui/screen/AnchorPopup.kt"))
    for path, expected in [
        ("app/src/main/java/com/ztransfer/ui/screen/AnchorPopup.kt", expected_popup_android),
        ("shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedAnchorPopup.kt", expected_popup),
        ("shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedFilterOverlay.kt", expected_filter),
        ("shared/src/commonMain/kotlin/com/ztransfer/ui/screen/FilterOverlayContract.kt", expected_contract()),
    ]:
        if (root / path).read_text(encoding="utf-8") != expected:
            raise ValueError("Original filter/calendar/popup extraction differs: " + path)
    if (root / file_list_path).read_text(encoding="utf-8") != expected_list:
        raise ValueError("File list changed beyond explicit collapse/signal/execution/grid/filter extraction adapters")
    if (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedThumbnailGrid.kt").read_text(encoding="utf-8") != expected_grid:
        raise ValueError("Shared thumbnail grid differs beyond image/index/text/lifecycle slots")
    if (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedQueueExecutionButton.kt").read_text(encoding="utf-8") != expected_execution:
        raise ValueError("Shared queue execution button differs beyond localized text/visibility changes")
    if (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedSignalPill.kt").read_text(encoding="utf-8") != expected_signal:
        raise ValueError("Shared signal pill differs beyond text/settings adapters and explicit unknown-RSSI capability")
    if (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/CollapseHeight.kt").read_text(encoding="utf-8") != expected_collapse:
        raise ValueError("Shared collapseHeight implementation differs from Android baseline")
    print("PASS entire shared queue body, Android service bindings/formatting/thumbnail loader, collapse layout, signal pill and execution button")
    print("PASS entire original thumbnail grid, burst/date reflow, gestures/bounds and Android image/index/text/lifecycle adapters")
    print("PASS entire original filter/date editor and popup; Android Java calendar/resources/width/back adapters")
    print("PASS original untransferred completion-exit coordinator and callback; shared by Android and iOS")
    preview_base = "app/src/main/java/com/ztransfer/ui/screen/"
    previews = extract_photo_viewport(original(preview_base + "PhotoPreview.kt"), original(preview_base + "PreviewRotationButton.kt"))
    model_android, preview_model = extract_photo_preview_model(previews[0])
    display = extract_photo_preview_display(model_android)
    histogram_button_android, histogram_button = extract_histogram_button(display[0])
    session_android, session_shared, session_contract = extract_photo_preview_session(histogram_button_android)
    previews = (session_android,) + previews[1:]
    for name, expected in [('SharedPhotoPreviewOverlay.kt', session_shared), ('PreviewSessionPlatform.kt', session_contract)]:
        if (root / ('shared/src/commonMain/kotlin/com/ztransfer/ui/screen/' + name)).read_text(encoding='utf-8') != expected:
            raise ValueError('Full original preview coordinator differs beyond explicit platform bindings: ' + name)
    monitor = extract_histogram(original(preview_base + "RemoteViewfinderFeatures.kt"))
    histogram_paths = [preview_base + "RemoteViewfinderFeatures.kt",
        "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/LuminanceHistogram.kt",
        "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedHistogram.kt",
        "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPreviewHistogramButton.kt"]
    for path, expected in zip(histogram_paths, (*monitor, histogram_button)):
        if (root / path).read_text(encoding="utf-8") != expected:
            raise ValueError("Original histogram analysis/rendering or Android remaining monitor differs: " + path)
    display_paths = ["SharedPhotoPreviewPage.kt", "SharedPhotoPreviewBurst.kt", "SharedPhotoPreviewDetails.kt", "PhotoPreviewDisplayPlatform.kt"]
    for name, expected in zip(display_paths, display[1:]):
        if (root / ("shared/src/commonMain/kotlin/com/ztransfer/ui/screen/" + name)).read_text(encoding="utf-8") != expected:
            raise ValueError(f"Original preview presentation changed beyond image/clock/text adapters: {name}")
    if (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPhotoPreviewModel.kt").read_text(encoding="utf-8") != preview_model:
        raise ValueError("Original preview paging/session/intent rules changed beyond visibility")
    preview_paths = [preview_base + "PhotoPreview.kt",
        "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedSinglePhotoPreviewOverlay.kt",
        "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedZoomablePreviewViewport.kt",
        preview_base + "PreviewRotationButton.kt",
        "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPreviewRotationButton.kt"]
    for path, expected in zip(preview_paths, previews):
        if (root / path).read_text(encoding="utf-8") != expected:
            raise ValueError(f"Original photo preview changed beyond viewport/back/text/math adapters: {path}")
    print("PASS entire original single-photo/zoom/rotation bodies; full preview coordinator shared with explicit Android IO/lifecycle/text adapters")
    print("PASS original preview paging/burst/source-snapshot/queue-intent rules; Android date, URI and IO paths retained")
    print("PASS original preview display/FHD reveal/video placeholder/burst stack/EXIF/navigation/transfer bodies and Android adapters")
    print("PASS original histogram sampling, linear normalization, plot/icon/button and complete Android remaining monitor/preview")
    print("PASS complete original preview FHD/EXIF/neighbor/cancel/burst/queue-flight coordination and common curve/easing")
    android_theme = (root / "app/src/main/java/com/ztransfer/ui/theme/Theme.kt").read_text(encoding="utf-8")
    def window_effect(text):
        block = text[text.index("val view = LocalView.current"):text.index("CompositionLocalProvider(")]
        return re.sub(r"\s+", "", re.sub(r"//[^\n]*", "", block))
    if window_effect(old_theme) != window_effect(android_theme):
        raise ValueError("Android system-bar side effects changed")
    print("PASS queue placement-only compatibility and original Android window effects")
    adapter = (root / "shared/src/androidMain/kotlin/com/ztransfer/ui/theme/TexturePlatform.android.kt").read_text(encoding="utf-8")
    if "Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888).asImageBitmap()" not in adapter:
        raise ValueError("Android original bitmap conversion changed")
    if "synchronized(monitor) { action() }" not in adapter:
        raise ValueError("Android cache monitor changed")
    print("PASS original texture body/cache order and Android bitmap/monitor adapter; 80-pixel-digest test runs with app unit tests")
    old_haptics_path = "app/src/main/java/com/ztransfer/ui/util/Haptics.kt"
    old_haptics = original(old_haptics_path)
    android_haptics = (root / "shared/src/androidMain/kotlin/com/ztransfer/ui/util/Haptics.android.kt").read_text(encoding="utf-8")
    if (root / old_haptics_path).exists() or android_haptics != expected_android_haptics(old_haptics):
        raise ValueError("Android haptic implementation differs beyond the adapter/interface extraction")
    pattern = old_haptics[old_haptics.index("const val PROGRESSIVE_HOLD_HAPTIC_DURATION_MS"):]
    expected_pattern = "package com.ztransfer.ui.util\n\n" + pattern.replace("private const val ", "internal const val ").replace("private val ", "internal val ")
    actual_pattern = (root / "shared/src/commonMain/kotlin/com/ztransfer/ui/util/ProgressiveHoldPattern.kt").read_text(encoding="utf-8")
    if actual_pattern != expected_pattern:
        raise ValueError("Original haptic waveform/amplitudes/durations changed")
    print("PASS original Android haptic branches/remember keys/delayed tick and complete waveform")
    import settings_controls_extraction as settings
    from directory_ui_wiring import previous_directory_ui_source
    settings_before = subprocess.check_output(['git', 'show', settings.BASELINE + ':' + settings.ANDROID], cwd=root).decode('utf-8')
    for path, expected in zip((settings.ANDROID, settings.COMMON), settings.extract(settings_before)):
        if previous_directory_ui_source(path, (root / path).read_text(encoding='utf-8')) != expected:
            raise ValueError(f"Original settings cards/platform callbacks changed beyond enumerated extraction: {path}")
    print("PASS complete original settings file with three shared cards/four helpers; directory, effects, GPS and license IO retained")
    print("Dependency upgrades, actual recomposition, screenshots, gestures and iOS rendering are NOT verified here.")


if __name__ == "__main__":
    main()
