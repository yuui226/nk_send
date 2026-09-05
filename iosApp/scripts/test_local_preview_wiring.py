"""Read-only guards; native file descriptors and ImageIO still require the Mac tests."""
from pathlib import Path
from original_reader_wiring import historical_source
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return historical_source(path)


class LocalPreviewWiringTest(unittest.TestCase):
    def test_original_decode_is_full_size_and_never_uses_thumbnail_or_orientation_transform(self):
        decoder = source('iosApp/ZTransfer/Storage/PreviewImageDecoder.swift')
        full = decoder.split('func originalBitmapPNG(', 1)[1].split('\n    ///', 1)[0]
        self.assertIn('CGImageSourceCreateImageAtIndex(source, 0,', full)
        for forbidden in ('CGImageSourceCreateThumbnail', 'maximumPixelSize', 'WithTransform', '1920', '2048'):
            self.assertNotIn(forbidden, full)
        android = source('app/src/main/java/com/ztransfer/frame/PhotoFrameExporter.kt')
        baseline = android.split('internal fun decodeOriginalPreview(', 1)[1].split('\n    /**', 1)[0]
        self.assertIn('maxEdge = null', baseline)
        self.assertIn('honorExifOrientation = false', baseline)

    def test_original_read_requires_exact_index_and_non_symlink_directory_descriptors(self):
        store = source('iosApp/ZTransfer/Storage/SandboxTransferFile.swift')
        read = store.split('func originalData(', 1)[1].split('\n    static func ', 1)[0]
        for required in ('originalIndex.entry(at: url)', 'entry.url.absoluteString == locator',
                         'O_DIRECTORY | O_NOFOLLOW', 'Darwin.openat(rootFD', 'Darwin.openat(folderFD',
                         'O_NONBLOCK', 'fstat(fileFD, &opened)', 'opened.st_size == entry.size',
                         '64 * 1024', 'try Task.checkCancellation()', 'defer { try? input.close() }'):
            self.assertIn(required, read)
        for forbidden in ('download(', 'camera.', 'scan(', 'O_WRONLY', 'O_CREAT', 'O_TRUNC'):
            self.assertNotIn(forbidden, read)

    def test_local_bridge_shares_slots_but_does_not_require_connection_or_touch_camera(self):
        bridge = source('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        self.assertIn('source: source, embeddedRaw: false, completion: completion)', bridge)
        self.assertIn('source: source, embeddedRaw: true, completion: completion)', bridge)
        read = bridge.split('private func readLocalPreview(', 1)[1].split('\n    func ', 1)[0]
        self.assertIn('previewRequests.count < 32', read)
        self.assertIn('previewUse?.session == sessionId', read)
        self.assertIn('self.queue.originalData(locator: source)', read)
        self.assertIn('self.decoder.originalBitmapPNG(data)', read)
        self.assertIn('defer { self.previewRequests.removeValue(forKey: key) }', read)
        for forbidden in ('connected', 'self.previews.', 'thumbnail(', 'fhd('):
            self.assertNotIn(forbidden, read)

    def test_local_source_is_frozen_at_open_and_uses_same_cancel_deadline_and_counter(self):
        model = source('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt')
        self.assertIn('localOriginalSource(file)?.let { file to it }', model)
        self.assertIn('isFrozenLocalSource = { file, source -> !closed && frozenSources[file] == source }', model)
        session = source('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePreviewReadSession.kt')
        local = session.split('suspend fun localBitmap(', 1)[1].split('private suspend fun', 1)[0]
        self.assertIn('localSource?.invoke(file, source) == true', local)
        self.assertNotIn('currentFile', local)
        self.assertIn('CancellableContinuation<*>', session)
        self.assertEqual(1, session.count('val request = ++nextRequest'))
        self.assertIn('withTimeoutOrNull(timeoutMillis)', session)
        self.assertNotIn('withTimeout(timeoutMillis)', session)
        self.assertIn('localSource = null', session)

    def test_local_png_has_separate_bulk_boundary_and_does_not_inherit_fhd_edge_limit(self):
        bridge = source('shared/src/iosMain/kotlin/com/ztransfer/ui/NativePreviewImageBridge.kt')
        local = bridge.split('fun localPng(', 1)[1].split('fun fhdPng(', 1)[0]
        self.assertEqual(1, local.count('memcpy('))
        self.assertIn('Int.MAX_VALUE.toULong()', local)
        self.assertIn('return ownedLocalPreviewPng(bytes)', local)
        payload = source('shared/src/commonMain/kotlin/com/ztransfer/ui/NativeLocalPreviewImage.kt')
        self.assertIn('maxEdge = Int.MAX_VALUE', payload)
        self.assertNotIn('1920', payload.split('internal fun ownedLocalPreviewPng', 1)[1])
