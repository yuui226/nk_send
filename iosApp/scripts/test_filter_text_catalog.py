from pathlib import Path
import unittest
from filter_text_catalog import expected_filter_catalog
from filter_overlay_extraction import KEYS


class FilterTextCatalogTest(unittest.TestCase):
    def test_all_three_languages_match_android_resources(self):
        root = Path(__file__).resolve().parents[2]
        self.assertEqual(expected_filter_catalog(root),
            (root/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilterTextCatalog.kt').read_text(encoding='utf-8'))

    def test_catalog_ordinal_order_covers_every_declared_filter_key(self):
        root = Path(__file__).resolve().parents[2]
        contract = (root/'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/FilterOverlayContract.kt').read_text(encoding='utf-8')
        self.assertIn('enum class FilterTextKey { '+', '.join(KEYS)+' }', contract)
        self.assertEqual(len(KEYS), len(set(KEYS)))
        source = expected_filter_catalog(root)
        for key in KEYS:
            self.assertEqual(3, source.count('// '+key+'\n'))
