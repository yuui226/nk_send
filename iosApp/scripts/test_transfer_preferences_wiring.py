"""Exact preference boundary/consumer guards; no claim of Swift or native control execution."""
from pathlib import Path
import subprocess
import unittest
from transfer_preferences_wiring import CHANGES, previous_transfer_source

ROOT = Path(__file__).resolve().parents[2]
MODEL = 'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt'
PAGE = 'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt'
BRIDGE = 'iosApp/ZTransfer/UI/OriginalFilesPage.swift'
STORE = 'iosApp/ZTransfer/Configuration/BrowsePreferencesStore.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'

def read(path): return (ROOT/path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', '73ba6cd:' + path], cwd=ROOT).decode('utf-8')

class TransferPreferencesWiringTest(unittest.TestCase):
    def test_whole_previous_consumers_restore_outside_the_enumerated_changes(self):
        self.assertEqual(6, len(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_transfer_source(path, read(path)))

    def test_default_options_and_destination_policy_are_the_existing_android_rules(self):
        android = read('app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt')
        for key in ('organize_transfers_by_date', 'defer_transfer_start'):
            self.assertIn(f'prefs.getBoolean("{key}", false)', android)
        preferences = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeTransferPreferences.kt')
        self.assertIn('organizeByDate = false, deferStart = false', preferences)
        self.assertIn('transferDestinationFolderName(file.captureDate, organizeByDate, dayKey)', preferences)
        for path in ('app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/TransferFilePolicy.kt',
                     'iosApp/ZTransfer/Network/CameraOriginalQueue.swift',
                     'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedSettingsControls.kt'):
            self.assertEqual(before(path), read(path))

    def test_admission_freezes_live_page_preferences_and_date_before_the_task_suspends(self):
        value = read(BRIDGE).split('    func enqueue(', 1)[1].split('    func thumbnail(', 1)[0]
        self.assertLess(value.index('let transfer = model.currentTransferPreferences(), dayKey = currentDayKey()'),
                        value.index('commands[token] = Task'))
        self.assertIn('byDate: transfer.organizeByDate, dayKey: dayKey, deferred: transfer.deferStart', value)
        self.assertNotIn('byDate: false', value)
        sample = read(PROBE).split('    func enqueueSample(', 1)[1].split('    func openSharedQueue()', 1)[0]
        self.assertIn('TransferPreferencesStore().read()', sample)
        self.assertIn('byDate: transfer.organizeByDate, dayKey: dayKey, deferred: transfer.deferStart', sample)

    def test_same_transfer_state_drives_badges_filter_preview_and_real_shared_controls(self):
        model = read(MODEL)
        self.assertEqual(2, model.count('folder = mutableTransfers.value.destinationFolder(file, currentDayKey())'))
        self.assertIn('filter(::isTransferred)', model)
        page = read(PAGE)
        self.assertIn('model.transferPreferences.collectAsState()', page)
        self.assertIn('criteria.untransferredOnly, transferPreferences.organizeByDate, lookupDayKey', page)
        self.assertIn('remember(file, originals.revision, transferPreferences.organizeByDate, lookupDayKey)', page)
        self.assertIn('produceState(0, model, transferPreferences.organizeByDate)', page)
        self.assertIn('value = model.currentDayKey()', page)
        host = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePhotoSettingsOverlay.kt')
        for token in ('SharedBooleanSettingsWheel(', 'model::setOrganizeByDate', 'model::setDeferStart',
                      'SettingsTextKey.organize_transfers_by_date', 'SettingsTextKey.defer_transfer_start'):
            self.assertIn(token, host)
        self.assertNotIn('SettingsTextKey.auto_transfer_new_media', host) # No inert automatic-event control.

    def test_transfer_storage_is_separate_bounded_and_cannot_overwrite_bad_or_future_data(self):
        value = read(STORE).split('final class TransferPreferencesStore {', 1)[1].split('/// One app-private', 1)[0]
        for token in ('"ztransfer.transfer.preferences"', 'data.count <= 4096', 'document.version == 1',
                      'guard read() != nil else { return false }', 'defaults.data(forKey: Self.key) == data'):
            self.assertIn(token, value)
        self.assertEqual(1, value.count('defaults.set('))
        for token in ('bookmark', 'removeObject', 'synchronize()', 'cameraID'):
            self.assertNotIn(token, value)
        model = read(MODEL)
        self.assertIn('if (closed || value == mutableTransfers.value) return', model)
        self.assertIn('mutableTransferPreferencesFailed.value = platform?.saveTransferPreferences(value) != true', model)
        self.assertIn('preferencesFailed || transferPreferencesFailed || appearanceState.preferencesFailed', read(PAGE))

    def test_guard_rejects_admission_and_date_lookup_mutations_without_hiding_original_changes(self):
        for path, old, new in ((BRIDGE, 'deferred: transfer.deferStart', 'deferred: false'),
                               (MODEL, 'mutableTransfers.value.destinationFolder(file, currentDayKey())', 'null'),
                               (STORE, 'data.count <= 4096', 'data.count <= 999999')):
            with self.assertRaises(AssertionError):
                previous_transfer_source(path, read(path).replace(old, new))
        value = read(BRIDGE).replace('func close() { model.close() }', 'func close() {}')
        self.assertNotEqual(before(BRIDGE), previous_transfer_source(BRIDGE, value))
