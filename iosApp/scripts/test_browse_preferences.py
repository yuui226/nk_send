"""Read-only guards, not a substitute for Swift compilation or UserDefaults runtime tests."""
from pathlib import Path
import plistlib
import unittest
from check_structure import OpenStepParser
from files_text_catalog import PREFERENCES_FAILURE

ROOT = Path(__file__).resolve().parents[2]

class BrowsePreferencesWiringTest(unittest.TestCase):
    def test_defaults_match_android_loaded_values_not_transient_ui_state(self):
        android = (ROOT/'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt').read_text(encoding='utf-8')
        shared = (ROOT/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeBrowsePreferences.kt').read_text(encoding='utf-8')
        self.assertIn('prefs.getBoolean("collapse_burst_photos", true)', android)
        self.assertIn('prefs.getInt("thumbnail_columns", 3)', android)
        self.assertIn('NativeBrowsePreferences(3, true, null, false, false, false, 0, 0)', shared)
        self.assertIn('normalizeThumbnailColumns(columns)', shared)
        self.assertIn('CaptureDayRange.between(startDay, endDay)', shared)

    def test_persistence_is_app_private_single_value_and_unknown_versions_are_preserved(self):
        store = (ROOT/'iosApp/ZTransfer/Configuration/BrowsePreferencesStore.swift').read_text(encoding='utf-8')
        self.assertIn('UserDefaults = .standard', store)
        self.assertIn('document.version == 1', store)
        self.assertIn('guard read() != nil else { return false }', store)
        self.assertEqual(1, store.count('defaults.set('))
        self.assertNotIn('removeObject', store)
        self.assertNotIn('synchronize()', store)
        self.assertNotIn('storageSlot', store)
        self.assertNotIn('Keychain', store)

    def test_restored_pending_filter_waits_for_actual_index_and_error_has_three_languages(self):
        page = (ROOT/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt').read_text(encoding='utf-8')
        self.assertIn('if (criteria.untransferredOnly && !originals.ready)', page)
        self.assertIn('rememberExportExitState(tasks.tasks, criteria.untransferredOnly && originals.ready, exportedHandles)', page)
        self.assertEqual({'english', 'simplified', 'traditional'}, set(PREFERENCES_FAILURE))
        self.assertIn('if (preferencesFailed) Text(text.preferencesFailed', page)

    def test_privacy_reason_is_registered_in_app_resources_exactly_once(self):
        manifest = plistlib.loads((ROOT/'iosApp/ZTransfer/Configuration/PrivacyInfo.xcprivacy').read_bytes())
        self.assertEqual([{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryFileTimestamp',
                          'NSPrivacyAccessedAPITypeReasons':['C617.1']},
                         {'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryUserDefaults',
                          'NSPrivacyAccessedAPITypeReasons':['CA92.1']}], manifest['NSPrivacyAccessedAPITypes'])
        project = OpenStepParser((ROOT/'iosApp/ZTransfer.xcodeproj/project.pbxproj').read_text(encoding='utf-8')).parse()
        objects = project['objects']
        resource = objects['7A1100000000000000000015']['files']
        self.assertEqual(1, resource.count('7A1200000000000000000064'))
        self.assertEqual('7A1200000000000000000065', objects['7A1200000000000000000064']['fileRef'])
        self.assertEqual('Configuration/PrivacyInfo.xcprivacy', objects['7A1200000000000000000065']['path'])
