"""Check the new automatic queue boundary, not a claim that camera events are already connected."""
from pathlib import Path
import subprocess
import unittest
from automatic_admission_wiring import CHANGES, previous_automatic_source

ROOT = Path(__file__).resolve().parents[2]
CORE = 'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/NativeOriginalTransferQueue.kt'
QUEUE = 'iosApp/ZTransfer/Network/CameraOriginalQueue.swift'
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', 'e575350:' + path], cwd=ROOT).decode('utf-8')
def between(value, start, end): return value.split(start, 1)[1].split(end, 1)[0]

class AutomaticAdmissionWiringTest(unittest.TestCase):
    def test_old_queue_worker_and_manual_admission_restore_exactly(self):
        self.assertEqual({CORE, QUEUE}, set(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_automatic_source(path, read(path)))

    def test_shared_batch_calls_original_android_identity_and_media_rules(self):
        value = between(read(CORE), '    fun enqueueNewMedia(', '    private fun enqueueFile(')
        for token in ('infos.size != files.size', 'newMediaQueueCandidates(files, tasks)',
                      'isAutoTransferMedia(file)', 'enqueueCatalog(checkNotNull(metadata[file]), file, byDate, dayKey)'):
            self.assertIn(token, value)
        self.assertNotIn('automaticTransferFileIdentity(', value)
        self.assertNotIn('TransferStatus.', value) # All history statuses follow the existing common rule.
        for path in ('shared/src/commonMain/kotlin/com/ztransfer/viewmodel/TransferTaskPolicy.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/CameraFilePublicationPolicy.kt',
                     'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt',
                     'app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt'):
            self.assertEqual(before(path), read(path))

    def test_apple_admission_stays_in_one_actor_turn_and_uses_existing_start_gate(self):
        value = between(read(QUEUE), '    func enqueueNewMedia(', '    func start()')
        self.assertIn('!Task.isCancelled, enabled, destination != nil, infos.count == files.count', value)
        self.assertIn('core.enqueueNewMedia(infos: infos, files: files, byDate: byDate, dayKey: dayKey)', value)
        self.assertIn('if core.shouldAutoStart(deferred: deferred) { start() }', value)
        self.assertIn('if accepted > 0', value)
        for token in ('await ', 'Task {', 'camera.', '.publish(', 'FileManager'):
            self.assertNotIn(token, value)

    def test_guards_reject_automatic_bypasses_without_hiding_manual_changes(self):
        for path, old, new in ((CORE, 'newMediaQueueCandidates(files, tasks)', 'files'),
                               (QUEUE, 'enabled, destination != nil,', 'enabled,')):
            with self.assertRaises(AssertionError):
                previous_automatic_source(path, read(path).replace(old, new))
        changed = read(QUEUE).replace('core.finishRun()', 'core.pauseAfterCurrent()')
        self.assertNotEqual(before(QUEUE), previous_automatic_source(QUEUE, changed))
