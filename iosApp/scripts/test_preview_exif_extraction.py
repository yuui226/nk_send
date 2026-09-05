"""Whole-source comparison: only EXIF pure parsing moves, no ViewModel IO/cache/state rewrite."""
from pathlib import Path
import subprocess
import unittest
import preview_exif_extraction as migration

ROOT = Path(__file__).resolve().parents[2]


class PreviewExifExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before = subprocess.check_output(['git', 'show', f'{migration.BASELINE}:{migration.ANDROID}'], cwd=ROOT).decode('utf-8').replace('\r\n', '\n')

    def test_complete_viewmodel_only_delegates_pure_exif_parsing(self):
        self.assertEqual(migration.android(self.before), (ROOT / migration.ANDROID).read_text(encoding='utf-8'))

    def test_complete_common_parser_has_only_enumerated_platform_substitutions(self):
        self.assertEqual(migration.common(self.before), (ROOT / migration.COMMON).read_text(encoding='utf-8'))

    def test_complete_android_adapter_preserves_tag_and_format_locale_mapping(self):
        self.assertEqual(migration.adapter(self.before), (ROOT / migration.ADAPTER).read_text(encoding='utf-8'))

    def test_entire_frozen_test_oracle_keeps_original_math_and_jvm_formatting(self):
        self.assertEqual(migration.oracle(self.before), (ROOT / migration.ORACLE).read_text(encoding='utf-8'))

    def test_existing_apple_photo_frame_reader_is_unchanged(self):
        path = 'iosApp/ZTransfer/Storage/PhotoMetadataReader.swift'
        before = subprocess.check_output(['git', 'show', f'{migration.BASELINE}:{path}'], cwd=ROOT).decode('utf-8').replace('\r\n', '\n')
        current = (ROOT / path).read_text(encoding='utf-8')
        start = current.index('/// Original preview Float rendering')
        end = current.index('/// Reads ImageIO properties', start)
        self.assertEqual(before, current[:start] + current[end:])
