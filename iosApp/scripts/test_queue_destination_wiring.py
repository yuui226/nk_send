"""Verify enumerated queue IO extensions without claiming Swift execution or provider parity."""
from pathlib import Path
import subprocess
import unittest
from queue_destination_wiring import previous_destination_source, without_destination_queue, without_destination_provider
from original_reuse_wiring import previous_reuse_source

ROOT = Path(__file__).resolve().parents[2]
BASE = '5921001'
QUEUE = 'iosApp/ZTransfer/Network/CameraOriginalQueue.swift'
PROVIDER = 'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'

# Batch 52 adds only the existing-original completion adapter. Keep the full previous
# reducer comparison: stripping this exact reviewed addition must restore the baseline.
EXISTING_COMPLETION = '''    /** Android's plain-original DL_SKIP branch: no download duration/speed or effect generation. */
    fun completedExisting(taskId: Long, bytes: Long) {
        if (activeId != taskId || bytes < 0) return
        tasks = tasks.map { task ->
            if (task.taskId == taskId) task.copy(status = TransferStatus.COMPLETED, skipped = true,
                progress = 1f, downloaded = bytes, speed = 0L) else task
        }
        activeId = null
        activeProgress = null
    }

'''
def read(path): return previous_reuse_source(path, (ROOT / path).read_text(encoding='utf-8'))
def before(path): return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode('utf-8')

class QueueDestinationWiringTest(unittest.TestCase):
    def test_entire_previous_implementations_preserved_outside_explicit_deltas(self):
        for path in (QUEUE, PROVIDER, PROBE, 'iosApp/ZTransfer/Storage/OriginalFilesReading.swift'):
            self.assertEqual(before(path), previous_destination_source(path, (ROOT / path).read_text(encoding='utf-8')))

    def test_complete_status_is_after_publication_not_download_and_share_result_is_app_owned(self):
        value = read(QUEUE).split('private func runNext()', 1)[1].split('private func finished()', 1)[0]
        publish = value.index('try await target.publish(saved, originalName: task.file.fileName, folder: task.destinationFolderName)')
        self.assertLess(value.index('stagedFiles[id] = saved'), publish)
        self.assertLess(publish, value.index('completedOriginalRevision &+= 1'))
        self.assertLess(publish, value.index('core.completed('))
        self.assertIn('savedFiles[task.taskId] = saved', value)
        self.assertIn('if target != nil, let retained = stagedFiles[id]', value)
        self.assertNotIn('Task.checkCancellation()', value[publish:])

    def test_destination_validation_checks_idle_both_sides_of_await_and_precedes_download(self):
        value = read(QUEUE)
        configure = value.split('func configureDestination(', 1)[1].split('@discardableResult', 1)[0]
        self.assertEqual(2, configure.count('guard worker == nil, !core.running'))
        self.assertLess(configure.index('try await value.validateSelection()'), configure.index('destination = value'))
        run = value.split('private func runNext()', 1)[1]
        self.assertLess(run.index('try await target.validateSelection()'), run.index('try await store.download'))
        self.assertEqual(1, value.count('destination = value'))

    def test_single_and_bulk_retries_only_map_io_context_from_shared_created_ids(self):
        value = read(QUEUE)
        self.assertIn('if let attempt = core.retry(taskId: taskID), let staged = stagedFiles.removeValue(forKey: taskID)', value)
        self.assertIn('core.retryFailed(excludedTaskIds:', value)
        self.assertIn('attempt.file == previous.file, attempt.destinationFolderName == previous.destinationFolderName', value)
        self.assertIn('stagedFiles[attempt.taskId] = staged', value)
        self.assertNotIn('nextId', value)
        for path in ('shared/src/commonMain/kotlin/com/ztransfer/viewmodel/NativeOriginalTransferQueue.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/TransferTaskPolicy.kt'):
            current = read(path)
            if path.endswith('/NativeOriginalTransferQueue.kt'):
                self.assertEqual(1, current.count(EXISTING_COMPLETION))
                current = current.replace(EXISTING_COMPLETION, '', 1)
            self.assertEqual(before(path), current)

    def test_existing_lookup_only_exposes_matched_metadata_from_the_original_kernel(self):
        path = 'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/NativeOriginalFileIndex.kt'
        current = read(path)
        replacements = (
            (
                '/** Metadata only; a locator never grants access to the underlying platform file. */\n'
                'data class NativeOriginalMatch(val name: String, val size: Long, val locator: String)\n\n'
                '/** Single owner (UI or IO actor). Same lookup/copy-suffix/size rules as Android directory indexes. */\n'
                'class NativeOriginalFileIndex {',
                '/** Single UI owner. Same compiled lookup/copy-suffix/size rules used by Android directory indexes. */\n'
                'internal class NativeOriginalFileIndex {',
            ),
            (
                '        find(file, folder)?.locator\n\n'
                '    /** Return the selected LOCAL name/size, not the requested camera name/unknown-size sentinel. */\n'
                '    fun find(file: CameraFileInfo, folder: String?): NativeOriginalMatch? =\n'
                '        buckets[transferDestinationLookupKey(folder)]?.find(file.fileName, file.size)?.let {\n'
                '            NativeOriginalMatch(it.displayName, it.size, it.value)\n'
                '        }',
                '        buckets[transferDestinationLookupKey(folder)]?.find(file.fileName, file.size)?.value',
            ),
        )
        for new, old in replacements:
            self.assertEqual(1, current.count(new))
            current = current.replace(new, old, 1)
        self.assertEqual(before(path), current)

    def test_android_existing_file_rules_and_plain_skip_branch_are_unchanged(self):
        for path in ('app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/TransferFilePolicy.kt'):
            self.assertEqual(before(path), read(path))

    def test_retained_original_lookup_cleanup_never_deletes_files(self):
        value = read(QUEUE)
        self.assertIn('savedFiles[taskID] ?? stagedFiles[taskID]', value)
        self.assertIn('stagedFiles.removeValue(forKey: taskID)', value)
        self.assertIn('stagedFiles = stagedFiles.filter { retained.contains($0.key) }', value)
        self.assertNotIn('removeItem(', value)
        self.assertNotIn('FileManager', value)

    def test_original_camera_name_is_optional_and_uses_exact_existing_verification_and_naming_body(self):
        value = read(PROVIDER)
        self.assertEqual(before(PROVIDER), without_destination_provider(value))
        self.assertIn('let name = originalName ?? saved.url.lastPathComponent', value)
        self.assertIn('SandboxTransferFile.safeComponent(name)', value)
        self.assertIn('!SandboxTransferFile.isPrivatePartName(name)', value)
        self.assertIn('copyDigest == saved.sha256', value)
        self.assertIn('PtpTransferBridge.shared.copyName(name: name, number:', value)

    def test_debug_target_configuration_and_page_borrow_same_owner_without_rebinding_active_grant(self):
        value = read(PROBE)
        self.assertIn('queue.configureDestination(target)', value)
        self.assertIn('guard originalQueue === queue', value)
        self.assertIn('transferDestination = target; savesToSelectedDirectory = enabled', value)
        self.assertIn('originals: originals ?? transferDestination)', value)
        self.assertIn('guard transferDestination == nil || (selection == nil && !forget)', value)
        self.assertIn('try await transferDestination.validateSelection()', value)
        self.assertIn('transferDestination = nil; savesToSelectedDirectory = false', value)
        self.assertEqual(1, value.count('for await snapshot in queue.updates'))

    def test_guard_detects_unlisted_changes_and_android_network_and_shared_page_remain_intact(self):
        with self.assertRaises(AssertionError):
            without_destination_queue(read(QUEUE).replace('originalName: task.file.fileName', 'originalName: saved.url.lastPathComponent'))
        self.assertNotEqual(before(QUEUE), without_destination_queue(read(QUEUE).replace('core.pauseAfterCurrent(); publish()', 'publish()')))
        for path in ('iosApp/ZTransfer/UI/OriginalFilesPage.swift', 'iosApp/ZTransfer/Storage/SandboxTransferFile.swift',
                     'iosApp/ZTransfer/Network/CameraWiFiConnection.swift',
                     'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt',
                     'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt'):
            self.assertEqual(before(path), read(path))

if __name__ == '__main__': unittest.main()
