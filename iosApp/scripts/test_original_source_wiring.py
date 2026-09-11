"""Real shared-page source binding and unchanged ownership; Apple behavior remains Mac-pending."""
from pathlib import Path
from queue_destination_wiring import previous_destination_source
import subprocess
import unittest
from original_source_wiring import without_original_source_page, without_original_source_probe, without_selection_validation

ROOT = Path(__file__).resolve().parents[2]
BASE = '3118b6a'
PAGE = 'iosApp/ZTransfer/UI/OriginalFilesPage.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'

def read(path): return previous_destination_source(path, (ROOT / path).read_text(encoding='utf-8'))
def before(path): return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode('utf-8')

class OriginalSourceWiringTest(unittest.TestCase):
    def test_entire_page_diff_is_immutable_source_injection_and_four_read_routes(self):
        self.assertEqual(before(PAGE), without_original_source_page(read(PAGE)))
        value = read(PAGE)
        self.assertIn('private let originals: OriginalFilesReading', value)
        self.assertIn('self.originals = originals ?? queue', value)
        for method in ('originals', 'originalData', 'originalRawPreviewData', 'originalExif'):
            self.assertEqual(1, value.count('self.originals.' + method + '('))
            self.assertNotIn('self.queue.' + method + '(', value)

    def test_source_boundary_is_only_read_methods_on_existing_actors(self):
        value = read('iosApp/ZTransfer/Storage/OriginalFilesReading.swift')
        self.assertIn('protocol OriginalFilesReading: Actor', value)
        self.assertEqual(4, value.count('    func '))
        for owner in ('CameraOriginalQueue', 'CameraOriginalStore', 'ProviderOriginalStore'):
            self.assertIn('extension ' + owner + ': OriginalFilesReading {}', value)
        for token in ('download(', 'publish(', 'select(', 'Task {', 'AsyncStream', 'var '):
            self.assertNotIn(token, value)

    def test_real_provider_entry_uses_same_page_and_has_no_implicit_sandbox_fallback(self):
        value = read(PROBE)
        self.assertEqual(before(PROBE), without_original_source_probe(value))
        entry = value.split('    func openSharedProviderFiles()', 1)[1].split('    func openSharedFiles(', 1)[0]
        self.assertLess(entry.index('try await source.validateSelection()'), entry.index('openSharedFiles(originals: source)'))
        self.assertLess(entry.index('try Task.checkCancellation()'), entry.index('openSharedFiles(originals: source)'))
        self.assertIn('apConnection?.connectionID == connection.connectionID', entry)
        self.assertIn('workspaceNavigation == navigation', entry)
        self.assertEqual(2, value.count('workspaceNavigation &+= 1'))
        self.assertNotIn('source.originals(', entry) # The page performs its own one initial scan.
        self.assertNotIn('openSharedFiles(', entry.split('} catch {', 1)[1])
        self.assertIn('stationMode: connection.stationMode, originals: originals)', value)
        self.assertIn('自动目录目标尚未接入', entry)

    def test_replacement_uses_existing_close_guards_instead_of_mutating_live_preview_source(self):
        probe, page = read(PROBE), read(PAGE)
        selection = probe.split('func useDirectory(', 1)[1].split('private func providerStore()', 1)[0]
        self.assertLess(selection.index('filesPage?.close(); filesPage = nil'), selection.index('try await store.select(selection)'))
        opening = probe.split('func openSharedFiles(', 1)[1].split('func pauseQueue()', 1)[0]
        self.assertLess(opening.index('filesPage?.close()'), opening.index('let page = OriginalFilesPageBridge('))
        self.assertIn('guard filesPage === page else { return }', opening)
        self.assertIn('closed = true; refreshTask?.cancel()', page)
        self.assertIn('originalIndexTask?.cancel(); originalIndexTask = nil', page)
        self.assertIn('previewRequests.values.forEach { $0.cancel() }', page)
        self.assertIn('guard !self.closed, !Task.isCancelled else { return }', page)
        self.assertEqual(1, page.count('self.originals ='))

    def test_no_camera_queue_shared_ui_parser_or_android_mutations_are_hidden(self):
        for path in ('iosApp/ZTransfer/Network/CameraOriginalQueue.swift', 'iosApp/ZTransfer/Network/CameraWiFiConnection.swift',
                     'iosApp/ZTransfer/Storage/SandboxTransferFile.swift', 'iosApp/ZTransfer/Storage/IndexedOriginalReader.swift',
                     'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt',
                     'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt'):
            self.assertEqual(before(path), read(path))
        path = 'iosApp/ZTransfer/Storage/ProviderOriginalStore.swift'
        self.assertEqual(before(path), without_selection_validation(read(path)))

    def test_guards_reject_unlisted_routing_lifecycle_or_preparation_changes(self):
        page = read(PAGE)
        with self.assertRaises(AssertionError):
            without_original_source_page(page.replace('self.originals.originalExif', 'self.queue.originalExif'))
        with self.assertRaises(AssertionError):
            without_original_source_probe(read(PROBE).replace('try await source.validateSelection()', 'try await source.originals(since: -1, rescan: true)'))
        self.assertNotEqual(before(PAGE), without_original_source_page(page.replace('closed = true;', 'closed = false;')))

    def test_new_entry_does_not_duplicate_queue_observers_or_imply_download_target_changed(self):
        probe = read(PROBE)
        self.assertEqual(1, probe.count('for await snapshot in queue.updates'))
        self.assertIn('filesPage?.publishQueue(snapshot)', probe)
        self.assertIn('已选目录入口只改变已保存识别与本地预览；下载队列当前仍写入应用沙盒。', probe)
        page = read(PAGE)
        self.assertIn('await self.queue.enqueueCatalog', page)
        self.assertNotIn('for await', page)
        self.assertNotIn('queue.stop', page)

if __name__ == '__main__': unittest.main()
