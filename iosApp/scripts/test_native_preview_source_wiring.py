"""Source/text/route guards. Native bitmap, Compose and clock execution still require Mac."""
from pathlib import Path
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


def read(path): return (ROOT / path).read_text(encoding='utf-8')


class NativePreviewSourceWiringTest(unittest.TestCase):
    def test_android_only_delegates_original_route_and_common_extensions_match_its_real_sets(self):
        path = 'app/src/main/java/com/ztransfer/ui/screen/PhotoPreview.kt'
        original = subprocess.check_output(['git', 'show', 'a174602:' + path], cwd=ROOT).decode('utf-8')
        old = '''internal fun localOriginalPreviewRoute(extension: String): LocalOriginalPreviewRoute = when {
    extension in NIKON_RAW_EXTENSIONS -> LocalOriginalPreviewRoute.RAW_EMBEDDED_JPEG
    extension in TIFF_EXTENSIONS -> LocalOriginalPreviewRoute.CAMERA_FHD
    else -> LocalOriginalPreviewRoute.DIRECT_BITMAP
}'''
        new = '''internal fun localOriginalPreviewRoute(extension: String): LocalOriginalPreviewRoute =
    originalLocalPreviewRoute(extension)'''
        self.assertEqual(1, original.count(old))
        self.assertEqual(original.replace(old, new), read(path))
        viewmodel = read('app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt')
        route = read('shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPreviewLocalRoute.kt')
        for original_name, case in (('NIKON_RAW_EXTENSIONS', 'RAW_EMBEDDED_JPEG'), ('TIFF_EXTENSIONS', 'CAMERA_FHD')):
            expected = set(re.findall(r'"([^\"]+)"', re.search(r'val ' + original_name + r' = setOf\(([^)]+)\)', viewmodel).group(1)))
            actual = set(re.findall(r'"([^\"]+)"', re.search(r'([^\n]+) -> LocalOriginalPreviewRoute\.' + case, route).group(1)))
            self.assertEqual(expected, actual)
        self.assertIn('else -> LocalOriginalPreviewRoute.DIRECT_BITMAP', route)
        self.assertNotIn('lowercase', route)

    def test_preview_labels_are_exactly_the_original_three_android_resource_sets(self):
        text = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePreviewTextCatalog.kt')
        keys = dict(burst='burst_label', protectedPhoto='filter_protected', histogram='cd_preview_histogram',
                    rotation='cd_rotate_photo', videoUnavailableLabel='video_no_preview', noPreviewLabel='no_preview',
                    overFourGb='video_size_over_4gb', expand='cd_expand', collapse='cd_collapse', transfer='cd_transfer')
        for language, values in [('english', 'values'), ('simplified', 'values-zh'), ('traditional', 'values-b+zh+Hant')]:
            block = text.split('private fun ' + language + '(', 1)[1].split('\n    )', 1)[0]
            resources = {x.attrib['name']: ''.join(x.itertext()) for x in ET.parse(ROOT / f'app/src/main/res/{values}/strings.xml').getroot().findall('string')}
            for field, key in keys.items():
                self.assertEqual(resources[key], re.search(r'\b' + field + r' = "([^\"]*)"', block).group(1), (language, key))
        self.assertIn('videoMetadata(file: CameraFileInfo): String = metadata(file, overFourGb)', text)
        self.assertNotIn('No date', text)

    def test_complete_native_source_delegates_all_io_priority_and_histogram_without_new_owners(self):
        text = read('shared/src/iosMain/kotlin/com/ztransfer/ui/NativePreviewSessionSource.kt')
        for expected in ('PreviewSessionSource<String>', 'grid.preview(reads, files)', 'originalLocalPreviewRoute(extension)',
                         'images.local(file, source)', 'images.localRaw(file, source)', 'LocalOriginalPreviewRoute.CAMERA_FHD -> null',
                         'images.fhd(file)', 'images.cached(handle)', 'images.thumbnail(file, allowRemote)',
                         'reads.localExif(file, source)', 'reads.exif(file)', 'reads.withInteractivePriority(block)',
                         'calculateImageLuminanceHistogram(bitmap)', 'NSProcessInfo.processInfo.systemUptime'):
            self.assertIn(expected, text)
        for forbidden in ('CameraWiFiConnection(', 'NativeQueuePageModel(', 'NativePreviewExifCache(', 'Dispatchers.',
                          'Image.makeFromEncoded', 'mutableStateMapOf', 'delay(', 'loadHighResolutionPage('):
            self.assertNotIn(forbidden, text)

    def test_source_freezes_full_identity_on_open_and_releases_only_its_overlay(self):
        text = read('shared/src/iosMain/kotlin/com/ztransfer/ui/NativePreviewSessionSource.kt')
        for expected in ('localSources.filterKeys { filesByHandle[it.handle] == it }.toMap()',
                         'sources.entries.associate', 'files.toList()', 'model.localOriginalSource(file)',
                         'model.beginPreviewReads()', 'sources[file] != source', 'filesByHandle[file.handle] != file',
                         'if (!active) close()', 'connection = null; sources = emptyMap(); filesBySource = emptyMap(); filesByHandle = emptyMap()',
                         'images.close()'):
            self.assertIn(expected, text)
        for forbidden in ('grid.close()', 'model.close()', 'queue.close()', 'LaunchedEffect', 'collectLatest'):
            self.assertNotIn(forbidden, text)


if __name__ == '__main__': unittest.main()
