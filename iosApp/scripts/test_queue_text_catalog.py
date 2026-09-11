from pathlib import Path
import unittest
from queue_text_catalog import expected_catalog


class QueueTextCatalogTest(unittest.TestCase):
    def test_all_queue_copy_matches_original_android_language_tables(self):
        root = Path(__file__).resolve().parents[2]
        actual = (root / 'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeQueueTextCatalog.kt').read_text(encoding='utf-8')
        self.assertEqual(expected_catalog(root), actual)

    def test_bridge_does_not_create_competing_queue_observer(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'iosApp/ZTransfer/UI/OriginalQueuePage.swift').read_text(encoding='utf-8')
        self.assertNotIn('for await', source)
        self.assertNotIn('queue.stop()', source)
        self.assertLess(source.index('self.publish(snapshot)'), source.index('func thumbnail('))
