"""Frozen Android oracle and exact adapter edits; not Apple execution or gesture proof."""
from pathlib import Path
import subprocess
import unittest
from preview_metadata_wiring import ORIGINAL_DATE, ORIGINAL_VIDEO, restore_preview_metadata, without_metadata_model, without_metadata_page

ROOT = Path(__file__).resolve().parents[2]
def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', 'd7f3b2c:' + path], cwd=ROOT).decode('utf-8')

class PreviewMetadataWiringTest(unittest.TestCase):
    def test_entire_android_preview_only_delegates_the_two_pure_text_functions(self):
        path = 'app/src/main/java/com/ztransfer/ui/screen/PhotoPreview.kt'
        self.assertEqual(before(path), restore_preview_metadata(read(path)))
        oracle = read('app/src/test/java/com/ztransfer/ui/screen/OriginalPreviewMetadataTextOracle.kt')
        date = ORIGINAL_DATE.replace('formatPreviewCaptureDate', 'originalPreviewCaptureDateText')
        video = ORIGINAL_VIDEO.replace('videoPreviewMetadata', 'originalPreviewVideoMetadataText').replace('formatPreviewCaptureDate', 'originalPreviewCaptureDateText')
        self.assertEqual(1, before(path).count(ORIGINAL_DATE)); self.assertEqual(1, before(path).count(ORIGINAL_VIDEO))
        self.assertEqual(oracle[oracle.index('internal fun '):], date + '\n' + video)

    def test_native_model_and_swift_page_only_add_formatting_callbacks(self):
        for path, normalize in [
            ('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt', without_metadata_model),
            ('iosApp/ZTransfer/UI/OriginalFilesPage.swift', without_metadata_page),
        ]:
            self.assertEqual(before(path), normalize(read(path)))

    def test_apple_metadata_readers_unchanged_outside_added_field_formatter(self):
        path = 'iosApp/ZTransfer/Storage/PhotoMetadataReader.swift'
        value = read(path)
        start = value.index('/// Gregorian field rendering only.')
        end = value.index('/// Reads ImageIO properties', start)
        self.assertEqual(before(path), value[:start] + value[end:])
        block = value[start:end]
        for forbidden in ('Calendar(', 'DateFormatter(', 'TimeZone(', '.currentCalendar'):
            self.assertNotIn(forbidden, block)

    def test_actual_native_entry_opens_original_shared_overlay_and_borrows_same_grid(self):
        host = read('shared/src/iosMain/kotlin/com/ztransfer/ui/SharedUiController.kt')
        self.assertIn('previewText = NativePreviewTextCatalog.forLanguage(languageTag, model::previewMetadata)', host)
        self.assertIn('openPreview = { files -> NativePreviewSessionSource.open(model, images, files) }', host)
        page = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt')
        for expected in ('SharedPhotoPreviewOverlay(', 'key(opening)', 'currentPreviewIdentity === identity',
                         'onTransferAsync = model::enqueue', 'localOriginalUriFor = opening.source::localSource',
                         'initialRotationQuarterTurns = previewOptions.rotationQuarterTurns',
                         'histogramVisible = previewOptions.histogramEnabled', 'queueTargetBounds = queueBounds',
                         'onDispose { previewBuildJob?.cancel(); preview?.source?.close() }',
                         'allowRemoteThumbnails = connected && preview == null', 'delay(760)',
                         'if (returnNonce == nonce) returnHandle = null', 'prepareDismissTarget = prepareDismiss',
                         'nativePreviewItems(', 'nativePreviewGridIndex(', 'nativePreviewScrollApproach('):
            self.assertIn(expected, page)
        self.assertEqual(1, page.count('latestOpenPreview(files)'))
        for forbidden in ('model.close()', 'queue.close()', 'CameraWiFiConnection('):
            self.assertNotIn(forbidden, page)

if __name__ == '__main__': unittest.main()
