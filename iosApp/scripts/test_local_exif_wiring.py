"""Descriptor/metadata wiring only. Darwin/ImageIO/Swift concurrency are Mac runtime gates."""
from pathlib import Path
import unittest
import struct

ROOT = Path(__file__).resolve().parents[2]
def source(path): return (ROOT / path).read_text(encoding='utf-8')


class LocalExifWiringTest(unittest.TestCase):
    def test_raw_rational_precision_requirement_has_a_reproducible_boundary_sample(self):
        # Mathematical motivation, not by itself proof of ImageIO/Android numerical parity.
        # The common binary-reader test exercises this same counterexample through raw overlay.
        f32 = lambda value: struct.unpack('f', struct.pack('f', value))[0]
        numerator, denominator = 36_293_949, 725_879_001
        android = f32(f32(numerator) / f32(denominator))
        imageio = f32(numerator / denominator)
        self.assertFalse(abs(android) < f32(0.05))
        self.assertTrue(abs(imageio) < f32(0.05))

    def test_raw_rationals_overlay_before_shared_formatting_on_actual_descriptor_path(self):
        reader = source('iosApp/ZTransfer/Storage/PreviewExifReader.swift')
        self.assertIn('final class PreviewExifFileReader: PreviewExifByteSource', reader)
        self.assertIn('NativePreviewExifRationalBridge.shared.read(source: reader, size: size)', reader)
        self.assertIn('guard rationals.complete else', reader)
        self.assertIn('rawRationals: rationals', reader)
        self.assertLess(reader.index('rawRationals?.applyTo(values: values)'), reader.index('return NativePreviewExifBridge.shared.metadata'))
        bridge = source('shared/src/iosMain/kotlin/com/ztransfer/preview/NativePreviewExifRationalBridge.kt')
        self.assertIn('PreviewExifRationalReader.read(source, size)', bridge)
        self.assertIn('bytes.usePinned { memcpy(', bridge)
        self.assertNotIn('catch', bridge)

    def test_raw_reader_keeps_numeric_source_out_of_android_production_call_sites(self):
        reader = source('shared/src/commonMain/kotlin/com/ztransfer/preview/PreviewExifRationalReader.kt')
        self.assertIn('denominator == 0L', reader)
        self.assertIn('target == PreviewExifTag.F_NUMBER || target == PreviewExifTag.EXPOSURE_TIME', reader)
        self.assertIn('"$numerator/$denominator"', reader)
        self.assertIn('count > maximumReadBytes', reader)
        self.assertIn('requests > 4096', reader)
        for path in (ROOT / 'app/src/main').rglob('*.kt'):
            self.assertNotIn('PreviewExifRationalReader', path.read_text(encoding='utf-8'))

    def test_local_metadata_uses_existing_indexed_descriptor_and_cancel_flag(self):
        store = source('iosApp/ZTransfer/Storage/SandboxTransferFile.swift')
        read = store.split('func originalExif(', 1)[1].split('private func withOriginalInput', 1)[0]
        for required in ('withTaskCancellationHandler', 'self.withOriginalInput(locator: locator',
                         'input.fileDescriptor', 'cancellation.cancel()', 'finalState.st_size == size'):
            self.assertIn(required, read)
        for forbidden in ('Data(contentsOf:', 'originalData(', 'scan(', 'camera.', 'download('):
            self.assertNotIn(forbidden, read)

    def test_imageio_reads_random_ranges_not_a_prefix_whole_file_or_reopened_url(self):
        reader = source('iosApp/ZTransfer/Storage/PreviewExifReader.swift')
        for required in ('CGDataProvider(directInfo: info, size: size, callbacks: &callbacks)',
                         'CGDataProviderDirectCallbacks', 'CGImageSourceCreateWithDataProvider',
                         'CGImageSourceCopyPropertiesAtIndex', 'Darwin.pread(', '64 * 1024',
                         'position >= 0, position <= size', 'size - position', 'errno == EINTR'):
            self.assertIn(required, reader)
        for forbidden in ('CGImageSourceCreateImageAtIndex', 'CGImageSourceCreateWithURL', 'Data(contentsOf:',
                          'mmap(', 'Darwin.open(', '128 * 1024', '2048 * 1024'):
            self.assertNotIn(forbidden, reader)

    def test_provider_owns_duplicate_until_release_and_cancel_is_thread_safe(self):
        reader = source('iosApp/ZTransfer/Storage/PreviewExifReader.swift')
        self.assertIn('Darwin.dup(fileDescriptor)', reader)
        self.assertIn('deinit { _ = Darwin.close(descriptor) }', reader)
        self.assertIn('F_SETFD, FD_CLOEXEC', reader)
        self.assertEqual(1, reader.count('Unmanaged.passRetained(reader)'))
        self.assertEqual(2, reader.count('Unmanaged<PreviewExifFileReader>.fromOpaque(info).release()'))
        self.assertIn('if cancellation.isCancelled { return loaded }', reader)
        self.assertIn('private let lock = NSLock()', reader)
        self.assertIn('if reader.failed { throw OriginalIndexError.incompleteMetadata }', reader)

    def test_imageio_metadata_calls_original_shared_preview_not_photo_frame_normalization(self):
        reader = source('iosApp/ZTransfer/Storage/PreviewExifReader.swift')
        self.assertIn('NativePreviewExifBridge.shared.metadata', reader)
        self.assertIn('values.setImageIoCoordinates', reader)
        self.assertIn('values.setImageIoAltitude', reader)
        self.assertIn('CFGetTypeID(number) != CFBooleanGetTypeID()', reader)
        self.assertIn('altitudeRef.rounded(.towardZero) == altitudeRef', reader)
        self.assertNotIn('PhotoFrameMetadata', reader)
        self.assertNotIn('NativePhotoMetadataBridge', reader)

    def test_local_exif_uses_shared_request_lifetime_and_cannot_fall_back_to_network(self):
        session = source('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePreviewReadSession.kt')
        local = session.split('suspend fun localExif(', 1)[1].split('private suspend fun', 1)[0]
        self.assertIn('localSource?.invoke(file, source) == true', local)
        self.assertIn('bridge.readLocalExif(sessionId, request, file, source', local)
        self.assertEqual(1, session.count('val request = ++nextRequest'))
        bridge = source('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        local = bridge.split('func readLocalExif(', 1)[1].split('func endPreviewReads', 1)[0]
        for required in ('previewRequests.count < 32', 'previewUse?.session == sessionId',
                         'self.queue.originalExif(locator: source)', 'self.previewRequests.removeValue(forKey: key)'):
            self.assertIn(required, local)
        for forbidden in ('connected', 'self.previews.', '.fhd(', 'thumbnail('): self.assertNotIn(forbidden, local)
