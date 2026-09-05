"""EXIF cache ownership/source guards; Swift actor execution still requires Mac."""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASE = 'ccccc01'


def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=ROOT).decode('utf-8')


class ExifCacheWiringTest(unittest.TestCase):
    def test_native_header_mapping_matches_actual_android_extension_contract(self):
        android = read('app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt')
        def extensions(name):
            return set(re.findall(r'"([^\"]+)"', re.search(r'val ' + name + r' = setOf\(([^)]+)\)', android).group(1)))
        shared = read('shared/src/commonMain/kotlin/com/ztransfer/preview/NativePreviewExifCache.kt')
        policy = shared.split('fun headerBytes(', 1)[1]
        small = set(re.findall(r'"([^\"]+)"', policy.split('-> 128 * 1024', 1)[0]))
        large = set(re.findall(r'"([^\"]+)"', policy.split('-> 128 * 1024', 1)[1].split('-> 2048 * 1024', 1)[0]))
        self.assertEqual(extensions('EXIF_SUPPORTED_EXTENSIONS'), small | large)
        self.assertEqual(extensions('NIKON_RAW_EXTENSIONS') | extensions('TIFF_EXTENSIONS'), large)
        self.assertIn('if (ext in LARGE_EXIF_HEADER_EXTENSIONS) 2048 * 1024 else 128 * 1024', android)
        self.assertIn('entries[exifKey(file)]', shared)
        self.assertNotIn('file.handle', shared)

    def test_long_lived_owner_injects_one_cache_without_altering_probe_or_image_store(self):
        path = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'
        value = read(path)
        self.assertEqual(1, value.count('NativePreviewExifCache()'))
        normalized = value.replace('    private let exifCache = NativePreviewExifCache()\n', '')
        normalized = normalized.replace('previews: previews, exifSource: connection, exifCache: exifCache, stationMode:', 'previews: previews, stationMode:')
        self.assertEqual(before(path), normalized)
        path = 'iosApp/ZTransfer/Network/CameraPreviewStore.swift'
        value = read(path)
        start = value.index('/// Borrowed transport only;')
        end = value.index('protocol CameraPreviewSource:', start)
        self.assertEqual(before(path), value[:start] + value[end:])

    def test_page_only_changes_exif_paths_and_explicit_borrowed_dependencies(self):
        path = 'iosApp/ZTransfer/UI/OriginalFilesPage.swift'
        current, original = read(path), before(path)
        value = current.replace('    private let exifSource: CameraExifSource\n', '').replace('    private let exifCache: NativePreviewExifCache\n', '')
        value = value.replace('previews: CameraPreviewStore,\n         exifSource: CameraExifSource, exifCache: NativePreviewExifCache, stationMode: Bool,',
                              'previews: CameraPreviewStore, stationMode: Bool,')
        value = value.replace('        self.exifSource = exifSource; self.exifCache = exifCache\n', '')
        start, end = value.index('    func readExif('), value.index('    func endPreviewReads(')
        old_start, old_end = original.index('    func readLocalExif('), original.index('    func endPreviewReads(')
        value = value[:start] + original[old_start:old_end] + value[end:]
        self.assertEqual(original, value)
        self.assertNotIn('NativePreviewExifCache()', current)
        self.assertNotIn('exifCache', current.split('func endPreviewReads(', 1)[1])

    def test_cache_lookup_precedes_io_and_offline_miss_does_not_become_negative_cache(self):
        page = read('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        remote = page.split('func readExif(', 1)[1].split('func readLocalExif(', 1)[0]
        local = page.split('func readLocalExif(', 1)[1].split('func endPreviewReads(', 1)[0]
        self.assertLess(remote.index('exifCache.cached(file: file)'), remote.index('guard connected, let use'))
        self.assertLess(remote.index('if maximum == 0'), remote.index('guard connected, let use'))
        self.assertEqual(1, remote.count('self.exifSource.exifHeader('))
        self.assertIn('self.decoder.exifMetadata(data)', remote)
        self.assertLess(local.index('exifCache.cached(file: file)'), local.index('self.queue.originalExif('))
        for body in (remote, local):
            self.assertIn('if !Task.isCancelled, !(error is CancellationError)', body)
            self.assertIn('self.previewUse?.session == sessionId', body)
            self.assertIn('self.exifCache.remember(file: file, exif: exif)', body)
        for forbidden in ('exifSource', 'previews.', 'connected'):
            self.assertNotIn(forbidden, local)

    def test_offline_cache_query_keeps_full_identity_and_uses_existing_decoder_actor(self):
        path = 'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt'
        line = '            isKnownExifFile = { file -> !closed && currentFiles[file.handle] == file },\n'
        value = read(path); self.assertIn(line, value)
        self.assertEqual(before(path), value.replace(line, ''))
        path = 'iosApp/ZTransfer/Storage/PreviewImageDecoder.swift'
        addition = '    func exifMetadata(_ header: Data) throws -> PhotoExif? {\n        try PreviewExifReader.metadata(header: header)\n    }\n\n'
        value = read(path); self.assertIn(addition, value)
        self.assertEqual(before(path), value.replace(addition, ''))


if __name__ == '__main__': unittest.main()
