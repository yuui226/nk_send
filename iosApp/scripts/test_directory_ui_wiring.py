"""Shared header and real picker ownership checks; native presentation still requires Mac."""
from pathlib import Path
import subprocess
import unittest
from directory_ui_wiring import CHANGES, previous_directory_ui_source

ROOT = Path(__file__).resolve().parents[2]
COMMON = 'shared/src/commonMain/kotlin/com/ztransfer/ui/'
CONTROLS = COMMON + 'screen/SharedSettingsControls.kt'
BRIDGE = 'iosApp/ZTransfer/UI/OriginalFilesPage.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', '5c7b253:' + path], cwd=ROOT).decode('utf-8')
def between(value, start, end): return value.split(start, 1)[1].split(end, 1)[0]

class DirectoryUIWiringTest(unittest.TestCase):
    def test_all_old_source_bodies_restore_exactly(self):
        self.assertEqual(5, len(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_directory_ui_source(path, read(path)))

    def test_shared_header_is_the_exact_original_row_and_android_still_calls_it(self):
        previous = before(CONTROLS).split('fun SharedTransferDirectorySettingsCard(', 1)[1]
        row = '        Row(verticalAlignment' + previous.split('        Row(verticalAlignment', 1)[1].split('\n\n        SharedCardDivider()', 1)[0]
        extracted = read(CONTROLS).split('fun SharedTransferDirectoryHeader(', 1)[1]
        actual = between(extracted, '    val colors = AppTheme.colors\n', '\n}\n')
        self.assertEqual('\n'.join(line[4:] if line.startswith('    ') else line for line in row.splitlines()), actual)
        card = read(CONTROLS).split('fun SharedTransferDirectorySettingsCard(', 1)[1]
        self.assertIn('SharedTransferDirectoryHeader(dirText, directoryAttentionActive, text, selectDirectory)', card)
        native = read(COMMON + 'NativePhotoSettingsOverlay.kt')
        self.assertIn('SharedTransferDirectoryHeader(directory.description, false, text, model.directory::choose)', native)
        # This historical stage had no automatic control; the later batch verifies its real wiring.
        from parallel_batch_wiring import previous_parallel_batch_source
        self.assertNotIn('SettingsTextKey.auto_transfer_new_media',
                         previous_parallel_batch_source(COMMON + 'NativePhotoSettingsOverlay.kt', native))

    def test_native_page_owns_request_lifetime_and_preserves_existing_warning_on_cancel(self):
        model = read(COMMON + 'NativeDirectorySettingsModel.kt')
        for token in ('closed || mutableState.value.selecting', 'requestId != request',
                      'message = message ?: mutableState.value.message', 'platform = null'):
            self.assertIn(token, model)
        self.assertIn('directory.close()', read(COMMON + 'NativeFilesPageModel.kt'))
        for token in ('bookmark', 'OriginalTransferQueue', 'CameraFileInfo'):
            self.assertNotIn(token, model)

    def test_picker_uses_real_folder_permissions_and_only_handles_its_own_controller(self):
        value = read(BRIDGE)
        self.assertIn('forOpeningContentTypes: [.folder], asCopy: false', value)
        self.assertIn('presenter.presentedViewController == nil', value)
        self.assertEqual(2, value.count('pending.controller === controller'))
        self.assertIn('controller.dismiss(animated: true) { [weak self]', value)
        self.assertIn('guard let self, !self.closed, let choose = self.directorySelection', value)
        self.assertIn('pending.controller.delegate = nil', value)
        self.assertIn('pending.controller.dismiss(animated: false)', value)
        self.assertNotIn('ScopedDirectoryStore', value) # No second commit implementation in the page.

    def test_actual_owner_receives_selection_and_returns_failures_to_the_page(self):
        value = read(PROBE)
        self.assertIn('self.selectQueueDirectory(url, completion: completion)', value)
        selection = between(value, '    func selectQueueDirectory(', '    private func providerStore()')
        self.assertIn('completion?(outcome)', selection)
        self.assertIn('outcome = directoryStatus', selection)
        self.assertLess(selection.index('queue.configureDestination(change)'), selection.index('filesPage?.close()'))
        self.assertIn('directoryDescription: queueDestinationSummary, directoryMessage: queueDestinationError', value)

    def test_guard_rejects_picker_bypass_and_does_not_hide_other_changes(self):
        for path, old, new in ((BRIDGE, 'asCopy: false', 'asCopy: true'),
                               (PROBE, 'completion?(outcome)', 'completion?(nil)')):
            with self.assertRaises(AssertionError):
                previous_directory_ui_source(path, read(path).replace(old, new))
        changed = read(BRIDGE).replace('func close() { model.close() }', 'func close() {}')
        self.assertNotEqual(before(BRIDGE), previous_directory_ui_source(BRIDGE, changed))
