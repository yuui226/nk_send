"""Native bitmap/cache wiring only; no claim of executing Skia or ImageIO on Windows."""
from pathlib import Path
import re
import struct
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
def source(path): return (ROOT / path).read_text(encoding='utf-8')


class PreviewBitmapWiringTest(unittest.TestCase):
    def test_native_decode_fixture_has_valid_png_chunks_and_exact_red_green_pixels(self):
        test = source('shared/src/iosTest/kotlin/com/ztransfer/ui/NativePreviewBitmapsIosTest.kt')
        literal = re.search(r'private fun png\(\) = byteArrayOf\((.*?)\)', test, re.S).group(1)
        png = bytes(int(x) & 255 for x in re.findall(r'-?\d+', literal))
        self.assertEqual(b'\x89PNG\r\n\x1a\n', png[:8])
        pos = 8; data = b''; kinds = []
        while pos < len(png):
            length = struct.unpack('>I', png[pos:pos+4])[0]
            kind = png[pos+4:pos+8]; payload = png[pos+8:pos+8+length]
            checksum = struct.unpack('>I', png[pos+8+length:pos+12+length])[0]
            self.assertEqual(checksum, zlib.crc32(kind + payload) & 0xffffffff)
            kinds.append(kind)
            if kind == b'IHDR': self.assertEqual((2, 1, 8, 6, 0, 0, 0), struct.unpack('>IIBBBBB', payload))
            if kind == b'IDAT': data += payload
            pos += length + 12
        self.assertEqual([b'IHDR', b'IDAT', b'IEND'], kinds)
        self.assertEqual(len(png), pos)
        self.assertEqual(b'\x00\xff\x00\x00\xff\x00\xff\x00\xff', zlib.decompress(data))

    def test_real_grid_and_preview_borrow_one_decoded_cache(self):
        host = source('shared/src/iosMain/kotlin/com/ztransfer/ui/SharedUiController.kt')
        grid = source('shared/src/iosMain/kotlin/com/ztransfer/ui/NativeGridImages.kt')
        preview = source('shared/src/iosMain/kotlin/com/ztransfer/ui/NativePreviewBitmaps.kt')
        self.assertIn('remember(model) { NativeGridImages(model) }', host)
        self.assertNotIn('class NativeGridImages', host)
        self.assertIn('NativePreviewBitmaps(reads, this, files)', grid)
        self.assertEqual(1, grid.count('LinkedHashMap<CameraFileInfo, ImageBitmap>'))
        self.assertNotIn('LinkedHashMap', preview)
        self.assertIn('owner?.cached(it)', preview)
        self.assertIn('owner?.thumbnail(file, allowRemote)', preview)
        self.assertIn('owner = null; filesByHandle = emptyMap()', preview)
        self.assertNotIn('owner?.close()', preview)

    def test_bitmap_decode_is_real_and_releases_temporary_image(self):
        native = source('shared/src/iosMain/kotlin/com/ztransfer/ui/NativePreviewBitmaps.kt')
        for required in ('Image.makeFromEncoded(encoded)', 'image.toComposeImageBitmap()',
                         'finally { image.close() }', 'withContext(Dispatchers.Default)',
                         'decodeNativePreviewBitmap(image.encoded, image.width, image.height, 1920)',
                         'decodeNativePreviewBitmap(image.encoded, image.width, image.height)',
                         'filesByHandle[file.handle] == file'):
            self.assertIn(required, native)

    def test_local_thumbnail_cannot_wait_for_or_issue_remote_request_or_cache_a_miss(self):
        store = source('iosApp/ZTransfer/Network/CameraPreviewStore.swift')
        local = store.split('private func localThumbnail(', 1)[1].split('\n    ///', 1)[0]
        self.assertIn('if !allowRemote { return try localThumbnail(info: info) }', store)
        self.assertIn('disk?.read(key: identity)', local)
        self.assertIn('allowedThumbnailKeys?.contains(identity) != false', local)
        for forbidden in ('await', 'pending[', 'source.', 'Task {', 'store(nil', 'load('):
            self.assertNotIn(forbidden, local)
        self.assertLess(local.index('guard info.identityComplete'), local.index('store(data, key: key)'))

    def test_remote_permission_reaches_existing_actor_without_being_overridden(self):
        model = source('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt')
        swift = source('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        self.assertIn('(allowRemote && !queue.connected.value)', model)
        self.assertIn('owner.thumbnail(file, allowRemote,', model)
        self.assertIn('(!allowRemote || connected)', swift)
        self.assertIn('self.previews.thumbnail(info: info, allowRemote: allowRemote)', swift)
        grid = source('shared/src/iosMain/kotlin/com/ztransfer/ui/NativeGridImages.kt')
        self.assertIn('currentCoroutineContext().ensureActive()', grid)
        self.assertIn('if (enabled && bitmap == null)', grid)
        self.assertIn('val result = load(file, remote)', grid)
        self.assertIn('!result.retryable || !remote', grid)
        self.assertIn('cache.size >= 128 || bytes + cost > 32L * 1024 * 1024', grid)
