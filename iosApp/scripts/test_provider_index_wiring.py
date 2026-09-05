"""Provider selection/index source preservation; actual Apple IO is covered by Mac-pending XCTest."""
from pathlib import Path
from original_reader_wiring import historical_source
import subprocess
import unittest
from provider_index_wiring import without_directory_selection, without_provider_index_cache, without_provider_index_probe

ROOT = Path(__file__).resolve().parents[2]
BASE = '5843705'
STORE = 'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift'
def read(path): return historical_source(path)
def before(path): return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode('utf-8')

class ProviderIndexWiringTest(unittest.TestCase):
    def test_sandbox_scanner_keeps_every_existing_branch_with_original_defaults(self):
        path = 'iosApp/ZTransfer/Storage/OriginalFileIndex.swift'
        self.assertEqual(before(path), without_provider_index_cache(read(path)))
        self.assertIn('missingRootIsEmpty: Bool = true', read(path))
        self.assertIn('checkCancellation: () throws -> Void = { try Task.checkCancellation() }', read(path))
        path = 'iosApp/ZTransfer/Storage/SandboxTransferFile.swift'
        self.assertEqual(before(path), read(path))

    def test_old_grant_store_behavior_is_unchanged_and_pinned_operations_never_rewrite_grant(self):
        path = 'iosApp/ZTransfer/Storage/ScopedDirectoryStore.swift'
        value = read(path)
        self.assertEqual(before(path), without_directory_selection(value))
        pinned = value.split('func withDirectory<T>(selection expected:', 1)[1].split('func displayName()', 1)[0]
        self.assertIn('guard try selection() == expected else { throw ExportDirectoryError.selectionChanged }', pinned)
        self.assertIn('access.resolve(expected.bookmark)', pinned)
        self.assertIn('defer { access.stop(resolved.url) }', pinned)
        self.assertNotIn('persist(', pinned)
        self.assertNotIn('bookmark(resolved', pinned)

    def test_original_verified_copy_algorithm_remains_exactly_the_previous_batch(self):
        marker = '    /// All filesystem operations here run inside BOTH the grant and coordinated accessor.'
        old = before('iosApp/ZTransfer/Storage/ProviderOriginalPublisher.swift')
        self.assertEqual(old[old.index(marker):], read(STORE)[read(STORE).index(marker):])

    def test_scanner_uses_coordinated_root_and_operation_local_cache_without_reading_photo_bytes(self):
        value = read(STORE)
        scan = value.split('func originals(since', 1)[1].split('private func boundSelection', 1)[0]
        for token in ('withDirectory(selection: selection)', 'coordinator.read(directory: granted) { root in',
                      'let scanned = OriginalFileIndexCache()',
                      'scanned.scan(root: root, missingRootIsEmpty: false, checkCancellation: control.check)',
                      'onCancel: { control.cancel() }'):
            self.assertIn(token, scan)
        self.assertNotIn('FileHandle', scan); self.assertNotIn('Data(contentsOf:', scan)
        self.assertIn('coordinate(readingItemAt: directory, options: [.withoutChanges]', value)

    def test_index_mutation_stays_on_owner_after_scan_generation_and_publication_checks(self):
        value = read(STORE)
        self.assertLess(value.index('guard generation == indexGeneration'), value.index('originalIndex.replaceEntries(entries)'))
        self.assertLess(value.index('let published = try await withTaskCancellationHandler'), value.index('originalIndex.record(published'))
        self.assertIn('originalIndex.record(published, folder: folder, canonicalURL: published.url)', value)
        self.assertIn('result.url.standardizedFileURL.resolvingSymlinksInPath()', value)
        self.assertIn('if !needsScan && canonicalRoot == previousRoot', value)
        self.assertIn('ProviderIndexScan(root: canonicalRoot, entries: nil)', value)
        self.assertLess(value.index('coordinator.read(directory: granted)'), value.index('if !needsScan && canonicalRoot == previousRoot'))
        self.assertIn('let bound = selection ?? candidate', value)

    def test_probe_reuses_one_directory_store_for_publish_and_scan_and_preserves_camera_logic(self):
        path = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'
        self.assertEqual(before(path), without_provider_index_probe(read(path)))
        self.assertIn('providerStore().originals(since: -1, rescan: true)', read(path))
        self.assertIn('providerStore().publish(saved, folder: folder)', read(path))
        self.assertIn('private var providerOriginals: ProviderOriginalStore?', read(path))

    def test_queue_and_shared_page_are_not_falsely_switched_to_unfinished_provider_target(self):
        for path in ('iosApp/ZTransfer/Network/CameraOriginalQueue.swift', 'iosApp/ZTransfer/UI/OriginalFilesPage.swift',
                     'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt',
                     'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt'):
            self.assertEqual(before(path), read(path))

if __name__ == '__main__': unittest.main()
