from pathlib import Path
import unittest
from files_text_catalog import expected_files_catalog, EXTRA, INDEX_FAILURE, INDEX_PENDING

class FilesTextCatalogTest(unittest.TestCase):
    def test_generated_grid_copy_is_exactly_android_and_explicit_integration_copy(self):
        root=Path(__file__).resolve().parents[2]
        self.assertEqual(expected_files_catalog(root), (root/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesTextCatalog.kt').read_text(encoding='utf-8'))
    def test_every_native_language_has_seven_failure_or_pending_messages(self):
        self.assertEqual({'english','simplified','traditional'}, set(EXTRA))
        for values in EXTRA.values(): self.assertEqual(10, len(values))
    def test_index_failure_is_separate_from_camera_scan_status_in_all_languages(self):
        self.assertEqual(set(EXTRA), set(INDEX_FAILURE))
        self.assertTrue(all(INDEX_FAILURE.values()))
        self.assertEqual(set(EXTRA), set(INDEX_PENDING))
        self.assertTrue(all(INDEX_PENDING.values()))
