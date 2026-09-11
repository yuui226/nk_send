"""Windows source/wiring guards. File coordination, scope and actual copying are Mac tests."""
from pathlib import Path
from original_reader_wiring import historical_source
import subprocess
import tempfile
import unittest
from check_structure import count_test_methods
from provider_publication_wiring import without_provider_publication_probe
from provider_index_wiring import without_directory_selection, without_provider_index_cache

ROOT = Path(__file__).resolve().parents[2]
BASE = '23b893e'
PUBLISHER = 'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'
def read(path): return historical_source(path)
def before(path): return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode('utf-8')

class ProviderPublicationWiringTest(unittest.TestCase):
    def test_probe_only_adds_explicit_publication_of_a_completed_saved_original(self):
        self.assertEqual(before(PROBE), without_provider_publication_probe(read(PROBE)))
        self.assertIn('saved.url == savedURL', read(PROBE))
        self.assertIn('PtpTransferBridge.shared.destinationFolder(captureDate: savedCaptureDate, byDate: byDate,', read(PROBE))
        self.assertIn('directoryTask?.cancel()', read(PROBE))

    def test_automatic_download_index_preview_and_android_paths_are_unchanged(self):
        for path in (
            'iosApp/ZTransfer/Storage/SandboxTransferFile.swift', 'iosApp/ZTransfer/Storage/OriginalFileIndex.swift',
            'iosApp/ZTransfer/Storage/ScopedDirectoryStore.swift', 'iosApp/ZTransfer/Network/CameraOriginalQueue.swift',
            'iosApp/ZTransfer/Network/CameraWiFiConnection.swift', 'iosApp/ZTransfer/UI/OriginalFilesPage.swift',
            'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt',
            'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt',
        ):
            normalize = without_directory_selection if path.endswith('ScopedDirectoryStore.swift') else (
                without_provider_index_cache if path.endswith('OriginalFileIndex.swift') else lambda value: value)
            self.assertEqual(before(path), normalize(read(path)))

    def test_scope_contains_coordinator_and_all_io_uses_accessor_supplied_urls(self):
        value = read(PUBLISHER)
        self.assertIn('try await directory.withDirectory(selection: selection) { granted in', value)
        self.assertIn('copy(source: saved.url, directory: granted) { input, output in', value)
        self.assertIn('coordinatedSource: input, coordinatedDirectory: output', value)
        self.assertIn('coordinate(readingItemAt: source, options: [], writingItemAt: directory, options: []', value)
        self.assertNotIn('private let coordinator = NSFileCoordinator', value)
        self.assertIn('let coordinator = NSFileCoordinator(filePresenter: nil)\n        lock.lock()', value)
        self.assertNotIn('camera.download(', value)
        self.assertNotIn('startAccessingSecurityScopedResource', value) # The existing lexical grant owner does this.

    def test_copy_and_readback_are_bounded_and_complete_before_publication(self):
        value = read(PUBLISHER)
        self.assertIn('Int(min(remaining, 64 * 1024))', value)
        self.assertNotIn('Data(contentsOf:', value)
        for token in ('info.st_size == saved.bytes', 'sourceDigest == saved.sha256', 'copyDigest == saved.sha256',
                      'input.read(upToCount: 1)', 'O_RDONLY | O_NOFOLLOW'):
            self.assertIn(token, value)
        self.assertLess(value.index('writer.synchronize()'), value.index('FileHandle(forReadingFrom: part)'))
        self.assertLess(value.index('copyDigest == saved.sha256'), value.index('moveItem(at: part, to: destination)'))

    def test_only_owned_unique_part_is_removed_and_names_use_shared_policy(self):
        value = read(PUBLISHER)
        self.assertEqual(1, value.count('removeItem('))
        self.assertIn('if ownsPart && !published { try? FileManager.default.removeItem(at: part) }', value)
        self.assertIn('options: [.withoutOverwriting]', value)
        self.assertIn('PtpTransferBridge.shared.copyName', value)
        self.assertIn('NativeOriginalIndexPolicy.shared.isDateFolder', value)
        self.assertIn('value.isDirectory == true, value.isSymbolicLink == false', value)
        self.assertNotIn('replaceItem', value)

    def test_cancellation_gates_wait_chunks_and_final_move_without_reversing_committed_success(self):
        value = read(PUBLISHER)
        for token in ('onCancel: { control.cancel() }', 'coordinator.cancel()', 'checkCancellation: control.check',
                      'while remaining > 0 {\n            try checkCancellation()',
                      'for number in 0...10_000 {\n            try checkCancellation()'):
            self.assertIn(token, value)
        success = value.split('published = true', 1)[1].split('} catch {', 1)[0]
        self.assertNotIn('try ', success)
        self.assertIn('return SavedCameraFile(', success)

    def test_xctest_counter_includes_multiple_source_files_and_nested_folders(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'One.swift').write_text('func testOne() {}\nfunc helper() {}', encoding='utf-8')
            (root / 'nested').mkdir()
            (root / 'nested/Two.swift').write_text('func testTwo() {}\nfunc testThree() {}', encoding='utf-8')
            self.assertEqual(3, count_test_methods(root))

if __name__ == '__main__': unittest.main()
