"""Whole-file preservation and preference contracts, not UserDefaults/Swift execution."""
from pathlib import Path
import subprocess
import unittest
from preview_preferences_wiring import without_preview_options_model
from preview_metadata_wiring import without_metadata_model

ROOT = Path(__file__).resolve().parents[2]


def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', '122cdf2:' + path], cwd=ROOT).decode('utf-8')


class PreviewPreferencesWiringTest(unittest.TestCase):
    def test_model_only_adds_preview_options_and_includes_them_in_existing_save(self):
        path = 'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt'
        value = read(path)
        self.assertEqual(before(path), without_preview_options_model(without_metadata_model(value)))
        setters = value.split('internal fun setPreviewRotationQuarterTurns(', 1)[1].split('private fun persistPreferences(', 1)[0]
        self.assertEqual(2, setters.count('if (closed) return'))
        self.assertEqual(2, setters.count('persistPreferences()'))
        for forbidden in ('beginPreviewReads', '.close()', 'mutableState.value', 'changeFilters(', 'changeLayout('):
            self.assertNotIn(forbidden, setters)

    def test_defaults_and_normalization_match_actual_android_restore_and_setters(self):
        android = read('app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt')
        common = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeBrowsePreferences.kt')
        self.assertIn('prefs.getInt("preview_rotation_quarter_turns", 0), 4', android)
        self.assertIn('"preview_histogram_enabled",\n                    false,', android)
        self.assertIn('val normalized = Math.floorMod(turns, 4)', android)
        self.assertIn('previewFloorMod(previewRotationQuarterTurns, 4)', common)
        self.assertIn('startDay, endDay, 0, false)', common)
        native = read('shared/src/iosMain/kotlin/com/ztransfer/ui/screen/PreviewPlatform.ios.kt')
        self.assertIn('value.mod(divisor)', native)

    def test_store_only_adds_optional_v1_fields_and_original_storage_guards_remain(self):
        path = 'iosApp/ZTransfer/Configuration/BrowsePreferencesStore.swift'
        value = read(path)
        addition = '''        // Optional additions to v1: existing installs restore the original 0 / false values.
        var previewRotationQuarterTurns: Int32?
        var previewHistogramEnabled: Bool?
'''
        self.assertEqual(1, value.count(addition)); value = value.replace(addition, '')
        value = value.replace('''endDay: document.endDay,
            previewRotationQuarterTurns: document.previewRotationQuarterTurns ?? 0,
            previewHistogramEnabled: document.previewHistogramEnabled ?? false)''', 'endDay: document.endDay)')
        value = value.replace('''endDay: value.endDay,
            previewRotationQuarterTurns: value.previewRotationQuarterTurns, previewHistogramEnabled: value.previewHistogramEnabled)''', 'endDay: value.endDay)')
        self.assertEqual(before(path), value)


if __name__ == '__main__': unittest.main()
