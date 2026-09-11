from pathlib import Path
from queue_destination_wiring import previous_destination_source
import unittest


class OriginalIndexWiringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.root = Path(__file__).resolve().parents[2]
    def read(self, name): return previous_destination_source(name, (self.root/name).read_text(encoding='utf-8'))

    def test_same_store_records_only_after_real_commit_before_completion(self):
        store = self.read('iosApp/ZTransfer/Storage/SandboxTransferFile.swift')
        self.assertLess(store.index('let saved = try output.commit'), store.index('originalIndex.record(saved'))
        queue = self.read('iosApp/ZTransfer/Network/CameraOriginalQueue.swift')
        self.assertLess(queue.index('let saved = try await store.download'), queue.index('completedOriginalRevision &+= 1'))
        self.assertIn('try await store.originals(since: revision, rescan: rescan)', queue)
        removal = queue[queue.index('func removeTask'):queue.index('func retry(')]
        self.assertNotIn('originalIndex', removal)
        self.assertNotIn('removeItem', removal)

    def test_page_uses_completed_revision_and_existing_single_observer(self):
        bridge = self.read('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        self.assertIn('value.completedOriginalRevision > completedOriginalRevision!', bridge)
        self.assertIn('try await self.originals.originals(since: self.originalRevision, rescan: rescan)', bridge)
        self.assertIn('originalIndexTask?.cancel()', bridge)
        self.assertNotIn('for await', bridge)
        page = self.read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt')
        self.assertIn('remember(file, originals.revision) { model.isTransferred(file) }', page)
        self.assertNotIn('isTransferred = { false }', page)

    def test_scan_does_not_follow_links_or_publish_partial_results(self):
        source = self.read('iosApp/ZTransfer/Storage/OriginalFileIndex.swift')
        for expression in ('if symbolic { continue }', 'if SandboxTransferFile.isPrivatePartName(name) { continue }',
                           'NativeOriginalIndexPolicy.shared.isDateFolder(name: name)',
                           'resolved.path.hasPrefix(canonicalRoot.path + "/")',
                           'allowDateDirectories: false', 'if journal.count > 1024'):
            self.assertIn(expression, source)
        self.assertGreater(source.index('publishFull(candidate)'), source.index('try scanFolder(canonicalRoot'))
        self.assertNotIn('removeItem', source)
        self.assertNotIn('Data(contentsOf:', source)
        self.assertLess(source.index('if symbolic { continue }'), source.index('let values = try child.resourceValues(forKeys: keys)'))
        self.assertIn('includingPropertiesForKeys: [.isSymbolicLinkKey]', source)
        parts = self.read('iosApp/ZTransfer/Storage/SandboxTransferFile.swift')
        self.assertIn('UUID(uuidString: String(suffix[..<separator]))', parts)
        self.assertIn('NativeOriginalIndexPolicy.shared.isPartName(name:', parts)
