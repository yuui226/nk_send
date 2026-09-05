"""Whole-source/wiring evidence only; Apple IO and UI tests still require Mac execution."""
from pathlib import Path
import subprocess
import unittest
from original_reuse_wiring import CHANGES, previous_reuse_source

ROOT = Path(__file__).resolve().parents[2]
QUEUE = 'iosApp/ZTransfer/Network/CameraOriginalQueue.swift'
READER = 'iosApp/ZTransfer/Storage/IndexedOriginalReader.swift'
PROVIDER = 'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift'
SANDBOX = 'iosApp/ZTransfer/Storage/SandboxTransferFile.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'

def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', 'd54f2d8:' + path], cwd=ROOT).decode('utf-8')

class OriginalReuseWiringTest(unittest.TestCase):
    def test_entire_previous_sources_restore_after_only_enumerated_additions(self):
        self.assertEqual(8, len(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_reuse_source(path, read(path)))

    def test_lookup_uses_one_shared_index_per_run_and_no_second_matching_algorithm(self):
        value = read(QUEUE)
        start = value.split('    func start() {', 1)[1].split('    func pauseAfterCurrent()', 1)[0]
        self.assertIn('originalLookup = NativeOriginalFileIndex()', start)
        lookup = value.split('    private func existingOriginal(', 1)[1].split('    func originals(', 1)[0]
        for token in ('originalLookup.revision, rescan: !originalLookup.hasSnapshot',
                      'NativeOriginalIndexUpdate(', 'guard update.add(', 'guard originalLookup.apply(update: update)',
                      'originalLookup.find(file: task.file, folder: task.destinationFolderName)',
                      'name: match.name, size: match.size, locator: match.locator'):
            self.assertIn(token, lookup)
        for token in ('lowercased', 'hasSuffix', 'replacingOccurrences', 'FileManager', 'fileExists'):
            self.assertNotIn(token, lookup)

    def test_existing_branch_precedes_all_camera_download_and_provider_publication(self):
        run = read(QUEUE).split('    private func runNext()', 1)[1].split('    private func finished()', 1)[0]
        existing = run.split('if let existing = try await existingOriginal(', 1)[1].split('            let saved: SavedCameraFile', 1)[0]
        self.assertIn('source = target', run); self.assertIn('source = store', run)
        self.assertIn('reusedFiles[id] = (source, existing)', existing)
        self.assertIn('core.completedExisting(taskId: id, bytes: existing.size)', existing)
        self.assertIn('return !Task.isCancelled', existing)
        self.assertIn('completedOriginalRevision &+= 1', existing)
        self.assertNotIn('savedFiles[', existing)
        self.assertNotIn('download(', existing); self.assertNotIn('publish(saved', existing)
        self.assertLess(run.index('existingOriginal('), run.index('store.download('))

    def test_sharing_commits_only_app_owned_part_after_scoped_copy_and_expected_length(self):
        body = read(QUEUE).split('    func prepareSavedFile(', 1)[1].split('    private func existingOriginal(', 1)[0]
        for first, second in [('store.makeShareFile(', 'reused.source.copyOriginal('),
                              ('reused.source.copyOriginal(', 'bytes == reused.reference.size'),
                              ('bytes == reused.reference.size', 'Task.checkCancellation()'),
                              ('Task.checkCancellation()', 'output.commit(expectedBytes: bytes)'),
                              ('output.commit(expectedBytes: bytes)', 'savedFiles[taskID] = saved')]:
            self.assertLess(body.index(first), body.index(second))
        self.assertIn('reusedFiles[taskID]?.reference == reused.reference', body)
        self.assertIn('output.discard()', body)
        self.assertNotIn('URL(string:', body)
        self.assertNotIn('core.failed', body)
        self.assertNotIn('FileManager', body)
        sandbox = read(SANDBOX).split('    func makeShareFile(', 1)[1].split('    static func applicationStore()', 1)[0]
        self.assertIn('root.appendingPathComponent("Shared Originals", isDirectory: true)', sandbox)
        self.assertNotIn('originalIndex.record', sandbox)

    def test_one_existing_descriptor_reader_serves_both_owners_with_bounded_memory(self):
        provider = read(PROVIDER).split('    func copyOriginal(', 1)[1].split('    /// Capture immutable', 1)[0]
        self.assertIn('withReader(locator: reference.locator)', provider)
        self.assertIn('$0.copyOriginal(reference, to: output)', provider)
        sandbox = read(SANDBOX).split('    func copyOriginal(', 1)[1].split('    /// Sharing', 1)[0]
        self.assertIn('reader(locator: reference.locator).copyOriginal(reference, to: output)', sandbox)
        body = read(READER).split('    func copyOriginal(', 1)[1].split('    /// Opens once', 1)[0]
        for token in ('entry?.name == reference.name', 'entry?.size == reference.size',
                      'withOriginalInput(locator: reference.locator', 'allowEmpty: true',
                      'min(remaining, 64 * 1024)', 'try output.write(chunk)',
                      'input.read(upToCount: 1)', 'fstat(input.fileDescriptor', 'finalState.st_size == size'):
            self.assertIn(token, body)
        self.assertNotIn('output.commit', body)
        self.assertNotIn('Data(contentsOf:', body)
        self.assertNotIn('data.append', body)
        self.assertIn('allowEmpty: Bool = false', read(READER))

    def test_skipped_flag_reaches_same_shared_queue_page_and_defaults_to_original_false(self):
        self.assertIn('status: task.status.name, skipped: task.skipped', read(QUEUE))
        self.assertIn('skipped: row.skipped', read('iosApp/ZTransfer/UI/OriginalQueuePage.swift'))
        model = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeQueuePageModel.kt')
        self.assertIn('skipped: Boolean = false', model)
        self.assertIn('downloadMBps = downloadMBps, skipped = skipped', model)

    def test_history_cleanup_and_share_navigation_cannot_resurrect_or_leak_a_provider_url(self):
        value = read(QUEUE)
        self.assertIn('reusedFiles.removeValue(forKey: taskID)', value)
        self.assertIn('reusedFiles = reusedFiles.filter { retained.contains($0.key) }', value)
        probe = read(PROBE)
        share = probe.split('    func shareQueueTask(', 1)[1].split('    func downloadSample(', 1)[0]
        self.assertIn('queueShareTask?.cancel()', share)
        self.assertIn('savedURL = nil; savedOriginal = nil; savedCaptureDate = nil', share)
        self.assertIn('try await queue.prepareSavedFile(id)', share)
        self.assertIn('originalQueue === queue', share)
        self.assertIn('state.rows.contains(where:', share)
        self.assertNotIn('await queue.savedFile(', share)
        self.assertIn('queueShareTask?.cancel()', probe.split('    func cancel()', 1)[1].split('    func previewSample', 1)[0])
        self.assertIn('queueShareTask?.cancel()', probe.split('    func disconnect()', 1)[1].split('    func canDownload', 1)[0])

    def test_guard_rejects_mutated_copy_and_skip_and_preserves_unrelated_changes(self):
        for path, old, new in ((QUEUE, 'bytes: existing.size', 'bytes: task.file.size'),
                               (READER, 'allowEmpty: Bool = false', 'allowEmpty: Bool = true'),
                               (PROVIDER, 'try $0.copyOriginal(reference, to: output)', 'Int64(0)')):
            with self.assertRaises(AssertionError):
                previous_reuse_source(path, read(path).replace(old, new))
        value = read(QUEUE).replace('core.pauseAfterCurrent(); publish()', 'publish()')
        self.assertNotEqual(before(QUEUE), previous_reuse_source(QUEUE, value))

    def test_android_and_shared_match_and_execution_rules_are_not_rewritten(self):
        for path in ('app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/NativeOriginalTransferQueue.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/NativeOriginalFileIndex.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/TransferFilePolicy.kt'):
            self.assertEqual(before(path), read(path))
