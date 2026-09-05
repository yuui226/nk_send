"""RAW wiring/ownership guards; ImageIO, Darwin and Kotlin/Native still need Mac execution."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path): return (ROOT / path).read_text(encoding='utf-8')


class NativeRawPreviewWiringTest(unittest.TestCase):
    def test_original_file_security_checks_are_reused_verbatim(self):
        path = 'iosApp/ZTransfer/Storage/SandboxTransferFile.swift'
        before = subprocess.check_output(['git', 'show', f'0d2f0b9:{path}'], cwd=ROOT).decode('utf-8').replace('\r\n', '\n')
        before = before.split('func originalData(locator: String) throws -> Data {\n', 1)[1].split('        var data = Data()', 1)[0]
        expected = before.replace('entry.size <= Int64(Int32.max)', 'entry.size <= maximumFileBytes')
        now = source(path).split('body: (FileHandle, Int64) throws -> T) throws -> T {\n', 1)[1].split('        return try body(input, entry.size)', 1)[0]
        self.assertEqual(expected, now)
        self.assertEqual(1, source(path).count('Darwin.openat(folderFD'))
        self.assertIn('maximumFileBytes: Int64(Int32.max)', source(path))
        self.assertIn('maximumFileBytes: Int64.max', source(path))

    def test_raw_reads_only_prefix_and_declared_ranges_with_same_owner(self):
        store = source('iosApp/ZTransfer/Storage/SandboxTransferFile.swift')
        raw = store.split('func originalRawPreviewData(', 1)[1].split('private func withOriginalInput', 1)[0]
        for required in ('withOriginalInput(locator: locator', 'LocalRawPreviewPolicy.shared.indexPrefixBytes',
                         'NativeRawPreviewBridge.shared.candidates', 'prefix.subdata', 'size - offset',
                         'input.seek(toOffset: UInt64(offset))', 'min(remaining, 64 * 1024)',
                         'try Task.checkCancellation()', 'finalState.st_size == size'):
            self.assertIn(required, raw)
        for forbidden in ('originalData(', 'Data(contentsOf:', 'scan(', 'camera.', 'download(', 'write('):
            self.assertNotIn(forbidden, raw)

    def test_bounds_probe_and_winner_use_shared_policy_not_raw_container_decode(self):
        decoder = source('iosApp/ZTransfer/Storage/PreviewImageDecoder.swift')
        bounds = decoder.split('static func rawPreviewPixels(', 1)[1].split('    /// DIRECT_BITMAP', 1)[0]
        self.assertIn('NativeRawPreviewBridge.shared.isCompleteJpeg', bounds)
        self.assertIn('CGImageSourceCopyPropertiesAtIndex', bounds)
        self.assertIn('LocalRawPreviewPolicy.shared.pixelCount', bounds)
        self.assertNotIn('CGImageSourceCreateImageAtIndex', bounds)
        store = source('iosApp/ZTransfer/Storage/SandboxTransferFile.swift')
        self.assertIn('LocalRawPreviewPolicy.shared.isBetter(pixelCount: pixels, previous: bestPixels)', store)
        bridge = source('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        self.assertIn('if embeddedRaw { data = try await self.queue.originalRawPreviewData(locator: source) }', bridge)
        self.assertIn('self.decoder.originalBitmapPNG(data)', bridge)

    def test_native_prefix_is_bounded_bulk_copy_and_contains_parser_exceptions(self):
        bridge = source('shared/src/iosMain/kotlin/com/ztransfer/preview/NativeRawPreviewBridge.kt')
        self.assertEqual(1, bridge.count('memcpy('))
        self.assertIn('data.length > LocalRawPreviewPolicy.indexPrefixBytes.toULong()', bridge)
        self.assertIn('try { LocalRawPreviewPolicy.candidates(prefix) } catch (_: Exception) { emptyList() }', bridge)
        self.assertIn('LocalRawPreviewPolicy.hasJpegEnvelope(', bridge)
        self.assertIn('bytes[size - 2]', bridge)

    def test_raw_session_shares_freeze_lifetime_and_full_bitmap_pipeline(self):
        session = source('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePreviewReadSession.kt')
        raw = session.split('suspend fun localRaw(', 1)[1].split('private suspend fun', 1)[0]
        self.assertIn('localSource?.invoke(file, source) == true', raw)
        self.assertIn('bridge.readLocalRaw(sessionId, request, source', raw)
        self.assertNotIn('currentFile', raw)
        self.assertEqual(1, session.count('val request = ++nextRequest'))
        bitmaps = source('shared/src/iosMain/kotlin/com/ztransfer/ui/NativePreviewBitmaps.kt')
        raw = bitmaps.split('suspend fun localRaw(', 1)[1].split('fun close()', 1)[0]
        self.assertIn('reads.localRaw(file, source)', raw)
        self.assertIn('decodeNativePreviewBitmap(image.encoded, image.width, image.height)', raw)
        self.assertNotIn('1920', raw)
