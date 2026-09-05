from pathlib import Path
import subprocess
import unittest
from histogram_extraction import extract_histogram, extract_histogram_button, expected_histogram_oracle
from photo_viewport_extraction import extract_photo_viewport
from photo_preview_model_extraction import extract_photo_preview_model
from photo_preview_display_extraction import extract_photo_preview_display
from thumbnail_grid_extraction import section

ROOT = Path(__file__).resolve().parents[2]
BASE = 'app/src/main/java/com/ztransfer/ui/screen/'
SHARED = 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/'


class HistogramExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        def original(name):
            return subprocess.run(['git', 'show', '55876fa:' + BASE + name], cwd=ROOT,
                check=True, capture_output=True, text=True, encoding='utf-8').stdout
        cls.source = original('RemoteViewfinderFeatures.kt')
        cls.remote = original('RemoteScreen.kt')
        cls.parts = extract_histogram(cls.source)
        cls.preview = extract_photo_preview_display(extract_photo_preview_model(
            extract_photo_viewport(original('PhotoPreview.kt'), original('PreviewRotationButton.kt'))[0])[0])[0]
        cls.button = extract_histogram_button(cls.preview)

    def test_complete_original_analysis_rendering_and_android_remainders_are_exact(self):
        paths = [BASE+'RemoteViewfinderFeatures.kt', SHARED+'LuminanceHistogram.kt', SHARED+'SharedHistogram.kt',
                 BASE+'PhotoPreview.kt', SHARED+'SharedPreviewHistogramButton.kt']
        for path, expected in zip(paths, (*self.parts, *self.button)):
            self.assertEqual(expected, (ROOT/path).read_text(encoding='utf-8'), path)

    def test_remaining_full_preview_coordinator_is_identical(self):
        anchor = 'internal fun PhotoPreviewOverlay('
        end = '@Composable\ninternal fun SinglePhotoPreviewOverlay('
        self.assertEqual(section(self.preview, anchor, end), section(self.button[0], anchor, end))
        for text in ('histogramVisible,\n        currentHandle,\n        histogramSource,',
                     'currentFile.extension !in PREVIEW_VIDEO_EXTENSIONS', 'withContext(Dispatchers.Default)',
                     'calculateLuminanceHistogram(histogramSource.asAndroidBitmap())'):
            self.assertIn(text, self.button[0])

    def test_remote_decode_and_histogram_throttle_are_entirely_unchanged(self):
        self.assertEqual(self.remote, (ROOT/BASE/'RemoteScreen.kt').read_text(encoding='utf-8'))
        for text in ('currentHistogramEnabled.value', 'histogramThrottle.cached == null',
                     'now - histogramThrottle.lastCalculatedAtMs >= 250L',
                     'histogramThrottle.cached = calculateLuminanceHistogram(bitmap)',
                     'histogramThrottle.cached = null'):
            self.assertIn(text, self.remote)

    def test_frozen_test_oracle_stays_exact_and_is_not_used_in_production(self):
        expected = expected_histogram_oracle(self.source)
        path = ROOT/'shared/src/commonTest/kotlin/com/ztransfer/ui/screen/OriginalLuminanceHistogramOracle.kt'
        self.assertEqual(expected, path.read_text(encoding='utf-8'))
        for body in (*self.parts, *self.button):
            self.assertNotIn('originalHistogramOracle', body)

    def test_android_keeps_getpixels_and_common_adapter_reads_one_sampled_row(self):
        android, core, ui = self.parts
        self.assertIn('bitmap.getPixels(row, 0, row.size, 0, y, row.size, 1)', android)
        self.assertIn('calculateLuminanceHistogram(bitmap.width, bitmap.height)', android)
        self.assertIn('val row = IntArray(width)', core)
        self.assertIn('readRow(y, row)', core)
        for text in ('startX = 0, startY = y, width = row.size, height = 1', 'bufferOffset = 0, stride = row.size'):
            self.assertIn(text, ui)
        for body in (core, ui, self.button[1]):
            for forbidden in ('android.', 'CameraViewModel', 'java.', 'R.string', 'BitmapFactory'):
                self.assertNotIn(forbidden, body)

    def test_sampling_weights_plot_and_button_values_remain_original(self):
        core, ui = self.parts[1:]
        for text in ('24_000.0', 'ceil(sqrt(', 'IntArray(256)', '(54 * red + 183 * green + 19 * blue) ushr 8',
                     'counts[i].toFloat() / peak', 'x += step', 'y += step'):
            self.assertIn(text, core)
        for text in ('118.dp, height = 62.dp', 'alpha = 0.48f', 'RoundedCornerShape(8.dp)',
                     'left + width * i / 255f', 'value.coerceIn(0f, 1f)', 'Stroke(1.05.dp.toPx()',
                     '0.38f, 0.62f, 0.85f, 0.55f, 0.28f', 'HistogramMarkStrokeWidth = 1.5.dp'):
            self.assertIn(text, ui)
        self.assertIn('val description = description()', self.button[1])
        self.assertIn('description = { stringResource(R.string.cd_preview_histogram) }', self.button[0])
        self.assertIn('active = active', self.button[1])
        self.assertIn('LocalContentColor provides colors.accentBlue', self.button[1])

    def test_algorithm_geometry_and_remaining_zebra_mutations_cannot_be_normalized(self):
        for before, after in [('24_000.0', '25_000.0'), ('54 * red', '55 * red'),
                              ('x += step', 'x += 1'), ('height = 62.dp', 'height = 63.dp'),
                              ('0.38f, 0.62f', '0.39f, 0.62f'), ('ZebraLumaThreshold = 242', 'ZebraLumaThreshold = 243')]:
            with self.subTest(before=before):
                self.assertIn(before, self.source)
                self.assertNotEqual(self.parts, extract_histogram(self.source.replace(before, after)))
