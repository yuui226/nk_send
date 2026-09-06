"""Source checks for restored destinations; not proof of UserDefaults/Apple execution."""
from pathlib import Path
import subprocess
import unittest
from destination_restore_wiring import CHANGES, previous_restore_source
from directory_ui_wiring import previous_directory_ui_source

ROOT = Path(__file__).resolve().parents[2]
PREFERENCES = 'iosApp/ZTransfer/Configuration/OriginalDestinationPreferences.swift'
QUEUE = 'iosApp/ZTransfer/Network/CameraOriginalQueue.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'

def read(path): return previous_directory_ui_source(path, (ROOT/path).read_text(encoding='utf-8'))
def before(path): return subprocess.check_output(['git', 'show', 'ce167b6:' + path], cwd=ROOT).decode('utf-8')
def between(value, start, end): return value.split(start, 1)[1].split(end, 1)[0]

class DestinationRestoreWiringTest(unittest.TestCase):
    def test_previous_queue_and_probe_restore_in_full(self):
        self.assertEqual({QUEUE, PROBE}, set(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_restore_source(path, (ROOT/path).read_text(encoding='utf-8')))

    def test_preference_is_explicit_bounded_and_does_not_guess_from_a_grant(self):
        value = read(PREFERENCES)
        for token in ('"ztransfer.original.destination"', 'data.count <= 1024', 'document.version == 1',
                      'guard read() != nil else { return false }', 'defaults.data(forKey: Self.key) == data'):
            self.assertIn(token, value)
        restore = between(value, '    func restore(', 'private struct OriginalDestinationUnavailable')
        sandbox = between(restore, 'if selected == .sandbox {', '        do {')
        self.assertIn('destination: nil', sandbox)
        self.assertNotIn('directory()', sandbox)
        self.assertIn('guard selected == .provider', restore)
        self.assertEqual(1, value.count('defaults.set('))
        self.assertNotIn('removeObject', value)

    def test_failed_restore_is_not_a_sandbox_or_empty_index_and_cancellation_escapes(self):
        value = read(PREFERENCES)
        failure = between(value, '        } catch {', '\nprivate struct')
        self.assertIn('if error is CancellationError { throw error }', failure)
        self.assertIn('try Task.checkCancellation()', failure)
        self.assertIn('destination: UnavailableOriginalDestination(message: message)', failure)
        blocked = value.split('private actor UnavailableOriginalDestination:', 1)[1]
        self.assertEqual(7, blocked.count('throw failure'))
        for token in ('CameraOriginalStore(', 'FileManager', 'return nil', 'OriginalIndexUpdate('):
            self.assertNotIn(token, blocked)

    def test_connection_publishes_only_a_restored_queue_and_uses_the_same_source_for_files(self):
        value = read(PROBE)
        start = between(value, '    private func inspectPersistentConnection(', '        queueObserver = Task {')
        self.assertLess(start.index('destinationPreferences.restore()'), start.index('let queue = CameraOriginalQueue'))
        self.assertLess(start.index('destination: restored.destination'), start.index('originalQueue = queue'))
        self.assertIn('transferDestination = restored.destination', start)
        self.assertIn('originals: originals ?? transferDestination', value)
        self.assertIn('Text(probe.queueDestinationSummary)', value)
        self.assertIn('if let queueDestinationError { return queueDestinationError }', value)
        self.assertIn('self.destination = destination', between(read(QUEUE), '    init(', '    deinit'))

    def test_explicit_choices_are_recorded_after_commit_and_save_failure_is_visible(self):
        value = read(PROBE)
        for start, end, configure, save in (
            ('    func selectQueueDirectory(', '    private func providerStore()', 'queue.configureDestination(change)', 'destinationPreferences.save(.provider)'),
            ('    func configureQueueDirectory(', '    func openSharedProviderFiles()', 'queue.configureDestination(target)', 'destinationPreferences.save(enabled ? .provider : .sandbox)')):
            section = between(value, start, end)
            self.assertLess(section.index(configure), section.index(save))
            self.assertIn('偏好保存失败', section)
            self.assertIn('queueDestinationError = nil', section)
        self.assertNotIn('destinationPreferences.save(', between(value, '    func useDirectory(', '    /// Prepare without'))

    def test_guards_reject_restore_order_mutations_and_leave_network_body_untouched(self):
        for path, old, new in ((QUEUE, 'self.destination = destination', 'self.destination = nil'),
                               (PROBE, 'destination: restored.destination', 'destination: nil')):
            with self.assertRaises(AssertionError):
                previous_restore_source(path, (ROOT/path).read_text(encoding='utf-8').replace(old, new))
        value = read(QUEUE).replace('core.finishRun()', 'core.pauseAfterCurrent()')
        self.assertNotEqual(before(QUEUE), previous_restore_source(QUEUE, value))
        for path in ('iosApp/ZTransfer/Network/CameraWiFiConnection.swift',
                     'iosApp/ZTransfer/Storage/ScopedDirectoryStore.swift',
                     'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/NativeOriginalTransferQueue.kt'):
            self.assertEqual(before(path), read(path))
