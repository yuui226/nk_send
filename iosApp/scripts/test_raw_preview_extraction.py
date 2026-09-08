"""Full-source baseline guards; these do not claim Swift/Native runtime validation."""
from pathlib import Path
import subprocess
import unittest
import raw_preview_extraction as migration
import local_raw_preview_extraction

ROOT = Path(__file__).resolve().parents[2]


class RawPreviewExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before = subprocess.check_output(
            ['git', 'show', f'{migration.BASELINE}:{migration.ANDROID}'], cwd=ROOT
        ).decode('utf-8').replace('\r\n', '\n')

    def test_entire_android_file_only_changes_to_parser_delegates(self):
        import sta_media_extraction as sta
        sta.verify()
        actual = sta.previous_sta_media_source(migration.ANDROID, (ROOT / migration.ANDROID).read_text(encoding='utf-8'))
        self.assertEqual(migration.android(self.before), actual)

    def test_entire_common_parser_matches_original_except_visibility_and_ascii_adapter(self):
        self.assertEqual(migration.common(self.before), (ROOT / migration.COMMON).read_text(encoding='utf-8'))

    def test_jvm_differential_oracle_is_the_unmodified_original_parser(self):
        path = 'app/src/test/java/com/ztransfer/protocol/rawbaseline/NefPreviewBaseline.kt'
        self.assertEqual(migration.oracle(self.before), (ROOT / path).read_text(encoding='utf-8'))

    def test_android_raw_io_is_unchanged_and_selection_calls_shared_original_rules(self):
        path = 'app/src/main/java/com/ztransfer/frame/PhotoFrameExporter.kt'
        before = subprocess.check_output(['git', 'show', f'{migration.BASELINE}:{path}'], cwd=ROOT).decode('utf-8')
        self.assertEqual(local_raw_preview_extraction.android(before.replace('\r\n', '\n')),
                         (ROOT / path).read_text(encoding='utf-8'))
