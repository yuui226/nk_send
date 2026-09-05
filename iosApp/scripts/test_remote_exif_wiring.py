"""Source-wiring guards only; Swift command/CGImageSource tests remain Mac execution gates."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASE = '42f4678'


def current(path):
    return (ROOT / path).read_text(encoding='utf-8')


def baseline(path):
    return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=ROOT).decode('utf-8')


class RemoteExifWiringTest(unittest.TestCase):
    def test_whole_connection_only_adds_exif_and_generalizes_existing_preview_parameters(self):
        path = 'iosApp/ZTransfer/Network/CameraWiFiConnection.swift'
        text = current(path)
        start = text.index('    /// Same partial-object command as Android readExifHeader.')
        end = text.index('    private func previewCommand(operation: Int32, parameters:', start)
        text = text[:start] + text[end:]
        text = text.replace('private func previewCommand(operation: Int32, parameters: [Int32], limit: Int,',
                            'private func previewCommand(operation: Int32, handle: Int32, limit: Int,', 1)
        text = text.replace('operationCode: operation, parameters: parameters, maximumPayloadBytes: limit,\n',
                            'operationCode: operation, parameters: [handle], maximumPayloadBytes: limit,\n', 1)
        self.assertEqual(baseline(path), text)

    def test_header_uses_shared_partial_fields_existing_gate_and_cancellation_contract(self):
        text = current('iosApp/ZTransfer/Network/CameraWiFiConnection.swift')
        body = text.split('    func exifHeader(', 1)[1].split('    private func previewCommand', 1)[0]
        for expected in ('PtpTransferBridge.shared.partialParameters', 'offset: 0, count: Int64(maximumBytes)',
                         'PtpConstants.shared.NK_GET_PARTIAL_OBJECT_EX', 'parameters: parameters, limit: Int(maximumBytes)',
                         'result.code == PtpConstants.shared.RESPONSE_OK', '!data.isEmpty',
                         'catch is CancellationError', 'if Task.isCancelled { throw CancellationError() }', 'await abort(error: error)'):
            self.assertIn(expected, body)
        for forbidden in ('CameraTCPStream(', 'PtpIPCommandSession(', 'while ', 'Task.sleep', 'download(', 'partialSupport ='):
            self.assertNotIn(forbidden, body)

    def test_header_path_cannot_relax_local_descriptor_rules_or_decode_an_image(self):
        path = 'iosApp/ZTransfer/Storage/PreviewExifReader.swift'
        text = current(path)
        original = baseline(path)
        descriptor = text.split('final class PreviewExifFileReader:', 1)[1].split('/// Immutable, already-bounded camera header;', 1)[0]
        previous = original.split('final class PreviewExifFileReader:', 1)[1].split('/// ImageIO extraction only.', 1)[0]
        self.assertEqual(previous, descriptor)
        local = text.split('static func metadata(fileDescriptor:', 1)[1].split('/// Dictionary-only calls', 1)[0]
        previous_local = original.split('static func metadata(fileDescriptor:', 1)[1].split('/// Dictionary-only calls', 1)[0]
        self.assertEqual(previous_local, local)
        header = text.split('static func metadata(header:', 1)[1].split('static func metadata(fileDescriptor:', 1)[0]
        for required in ('header.count <= 2 * 1024 * 1024', '.readHeader(', 'raw.complete || raw.partial',
                         'CGImageSourceCopyPropertiesAtIndex', 'rawRationals: raw', 'Task.checkCancellation()'):
            self.assertIn(required, header)
        for forbidden in ('CGImageSourceCreateImageAtIndex', 'FileHandle', 'Data(contentsOf:', 'readExifHeader('):
            self.assertNotIn(forbidden, header)


if __name__ == '__main__':
    unittest.main()
