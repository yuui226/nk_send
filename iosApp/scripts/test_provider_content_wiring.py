"""Guard the single reader implementation and lexical IO ownership; not Apple execution evidence."""
from pathlib import Path
from queue_destination_wiring import previous_destination_source
import subprocess
import unittest
from original_reader_wiring import READER, SANDBOX, restore_sandbox_reader
from original_source_wiring import without_original_source_page, without_original_source_probe

ROOT = Path(__file__).resolve().parents[2]
BASE = '381364e'
PROVIDER = 'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift'

def read(path): return previous_destination_source(path, (ROOT / path).read_text(encoding='utf-8'))
def before(path): return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode('utf-8')

class ProviderContentWiringTest(unittest.TestCase):
    def test_entire_sandbox_source_restores_with_exact_reader_bodies_and_delegates(self):
        self.assertEqual(before(SANDBOX), restore_sandbox_reader(read(SANDBOX)))
        reader = read(READER)
        for token in ('Darwin.openat(folderFD', 'NativeRawPreviewBridge.shared.candidates',
                      'PreviewExifReader.metadata(fileDescriptor:'):
            self.assertEqual(1, reader.count(token))
            self.assertNotIn(token, read(SANDBOX))
            self.assertNotIn(token, read(PROVIDER))

    def test_normalization_does_not_hide_reader_or_delegation_mutations(self):
        sandbox, reader = read(SANDBOX), read(READER)
        with self.assertRaises(ValueError):
            restore_sandbox_reader(sandbox.replace('try reader(locator: locator).originalData', 'try other(locator: locator).originalData'), reader)
        with self.assertRaises(ValueError):
            restore_sandbox_reader(sandbox, reader.replace('if cancellation.isCancelled', 'if false'))
        self.assertNotEqual(before(SANDBOX), restore_sandbox_reader(sandbox, reader.replace('opened.st_size == entry.size', 'true')))
        self.assertNotEqual(before(SANDBOX), restore_sandbox_reader(sandbox, reader.replace('bestPixels = pixels', 'bestPixels = 1')))

    def test_content_uses_single_file_coordination_with_latest_pending_edits_not_metadata_only(self):
        value = read(PROVIDER)
        content = value.split('    func contents<T>(file:', 2)[2].split('private func withCoordinator', 1)[0]
        self.assertIn('try withCoordinator { coordinator in', content)
        self.assertIn('coordinate(readingItemAt: file, options: [], error: &failure)', content)
        self.assertIn('result = Result { try accessor(url) }', content)
        self.assertIn('if let failure { throw failure }', content)
        self.assertNotIn('.withoutChanges', content)
        self.assertNotIn('FileHandle', content)

    def test_provider_uses_frozen_index_and_rejects_old_root_or_redirected_file(self):
        value = read(PROVIDER)
        owner = value.split('private func withReader<T>', 1)[1].split('private func boundSelection', 1)[0]
        for token in ('originalIndex.entry(at: url)', 'entry.url.absoluteString == locator',
                      'let expectedRoot = indexedRoot', 'withDirectory(selection: selection)',
                      'granted.standardizedFileURL.resolvingSymlinksInPath() == expectedRoot',
                      'control.coordinator.contents(file: entry.url) { actual in',
                      'guard actual == entry.url', 'folder: entry.folder, url: actual)',
                      'IndexedOriginalReader(root: granted, entry: coordinatedEntry, cancellation: cancellation)'):
            self.assertIn(token, owner)
        self.assertLess(owner.index('== expectedRoot'), owner.index('coordinator.contents('))
        self.assertLess(owner.index('withDirectory('), owner.index('IndexedOriginalReader('))
        for token in ('originalIndex.record', 'originalIndex.scan', 'Data(contentsOf:', 'camera.', 'download(', 'self.'):
            self.assertNotIn(token, owner)

    def test_all_three_routes_use_same_grant_and_cancellation_handler(self):
        value = read(PROVIDER)
        routes = value.split('    func originalData(', 1)[1].split('    /// Capture immutable', 1)[0]
        self.assertEqual(3, routes.count('try await withReader(locator: locator)'))
        owner = value.split('private func withReader<T>', 1)[1].split('private func boundSelection', 1)[0]
        self.assertIn('onCancel: { control.cancel(); cancellation.cancel() }', owner)
        self.assertIn('let result = try read(', owner)
        self.assertIn('try control.check()\n                    return result', owner)
        self.assertIn('if cancellation.isCancelled { throw CancellationError() }', read(READER))

    def test_previous_provider_publication_and_scan_are_unchanged(self):
        old, new = before(PROVIDER), read(PROVIDER)
        for start, end in [('    func publish(', '    func originalData('),
                           ('    private func boundSelection', None)]:
            if start.startswith('    func publish'):
                expected = old[old.index(start):old.index('    private func boundSelection')]
                actual = new[new.index(start):new.index(end)]
            else:
                expected, actual = old[old.index(start):], new[new.index(start):]
            self.assertEqual(expected, actual)

    def test_page_queue_and_shared_or_android_execution_are_not_changed_by_reader_extraction(self):
        for path in ('iosApp/ZTransfer/UI/OriginalFilesPage.swift', 'iosApp/ZTransfer/Network/CameraOriginalQueue.swift',
                     'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift', 'iosApp/ZTransfer/Storage/PreviewExifReader.swift',
                     'iosApp/ZTransfer/Storage/PreviewImageDecoder.swift', 'iosApp/ZTransfer/Storage/OriginalFileIndex.swift',
                     'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt'):
            normalize = without_original_source_page if path.endswith('OriginalFilesPage.swift') else (
                without_original_source_probe if path.endswith('CameraHandshakeProbe.swift') else lambda value: value)
            self.assertEqual(before(path), normalize(read(path)))

    def test_apple_tests_do_not_place_await_in_xctest_synchronous_autoclosures(self):
        for path in (ROOT / 'iosApp/ZTransferTests').rglob('*.swift'):
            for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
                self.assertNotRegex(line, r'XCT\w+\([^\n]*\bawait\b', f'{path.name}:{number}')

if __name__ == '__main__': unittest.main()
