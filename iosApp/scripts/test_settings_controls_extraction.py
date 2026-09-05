"""Whole original settings-file preservation and real Native preference/entry wiring."""
from pathlib import Path
import subprocess
import unittest
import settings_controls_extraction as migration
import settings_text_catalog
from photo_settings_wiring import without_photo_interaction_model, without_photo_interaction_store

ROOT = Path(__file__).resolve().parents[2]
def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', migration.BASELINE + ':' + path], cwd=ROOT).decode('utf-8')

class SettingsControlsExtractionTest(unittest.TestCase):
    def test_android_resource_newline_is_not_rendered_as_literal_backslash_n(self):
        self.assertEqual('Tap: preview\nHold: transfer', settings_text_catalog.android_resource_value(r'Tap: preview\nHold: transfer'))
        self.assertEqual(r'keep\n', settings_text_catalog.android_resource_value(r'keep\\n'))
        with self.assertRaises(KeyError): settings_text_catalog.android_resource_value(r'new\qescape')

    def test_entire_android_settings_preserves_effects_gps_licenses_directory_picker_and_footer(self):
        android, _ = migration.extract(before(migration.ANDROID))
        self.assertEqual(android, read(migration.ANDROID))

    def test_all_three_shared_cards_and_four_helpers_keep_original_layout_and_commit_behaviors(self):
        _, common = migration.extract(before(migration.ANDROID))
        self.assertEqual(common, read(migration.COMMON))
        for forbidden in ('android.', 'TransferViewModel', 'LicenseManager', 'AppUpdateManager', 'LocalContext'):
            self.assertNotIn(forbidden, common)
        self.assertIn('if (language.first != appLanguage)', common)
        self.assertIn('onLanguage(language.first)\n                        close()', common)
        self.assertIn('hapticsEnabled || isHapticsPreference', common)
        self.assertEqual(3, common.count('enabled = hasDirectory'))

    def test_native_strings_are_exactly_the_original_three_resource_sets(self):
        self.assertEqual(settings_text_catalog.generate(ROOT), read(settings_text_catalog.PATH))

    def test_native_model_and_store_only_extend_interaction_preference(self):
        for path, normalize in [
            ('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt', without_photo_interaction_model),
            ('iosApp/ZTransfer/Configuration/BrowsePreferencesStore.swift', without_photo_interaction_store),
        ]:
            self.assertEqual(before(path), normalize(read(path)))
        android = read('app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt')
        self.assertIn('prefs.getBoolean("tap_to_preview", false)', android)

    def test_actual_native_page_consumes_setting_and_uses_original_card_not_duplicate_controls(self):
        page = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt')
        self.assertIn('tapToPreview = layout.tapToPreview', page)
        self.assertIn('NativePhotoSettingsOverlay(model, layout, settingsText, frozenAnchor)', page)
        host = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePhotoSettingsOverlay.kt')
        self.assertIn('SharedPhotoListSettingsCard(', host)
        self.assertIn('onTapToPreview = model::setTapToPreview', host)
        self.assertIn('val openingAnchor = remember { anchor }', host)
        self.assertNotIn('SharedTransferDirectorySettingsCard(', host)  # No unconnected directory controls.
        self.assertNotIn('SharedAppearanceSettingsCard(', host)  # Appearance owner still pending.

if __name__ == '__main__': unittest.main()
