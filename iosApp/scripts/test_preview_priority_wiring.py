"""Exact unaffected-source guards, not execution of the Swift FIFO or Apple UI."""
from pathlib import Path
import subprocess
import unittest
from preview_priority_wiring import without_priority_connection, without_priority_page
from preview_metadata_wiring import without_metadata_page

ROOT = Path(__file__).resolve().parents[2]
BASE = 'c7cb39e'


def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=ROOT).decode('utf-8')


class PreviewPriorityWiringTest(unittest.TestCase):
    def test_connection_and_page_only_add_priority_registration_and_release(self):
        for path, normalize in (
            ('iosApp/ZTransfer/Network/CameraWiFiConnection.swift', without_priority_connection),
            ('iosApp/ZTransfer/UI/OriginalFilesPage.swift', lambda value: without_priority_page(without_metadata_page(value))),
        ):
            self.assertEqual(before(path), normalize(read(path)))

    def test_streaming_rechecks_priority_before_tid_and_existing_wire_loops_remain_identical(self):
        path = 'iosApp/ZTransfer/Network/PtpIPCommandSession.swift'
        value, original = read(path), before(path)
        for addition in ('        let transferSlice: Bool\n', '    private var interactiveUses = Set<UUID>()\n',
                         '        interactiveUses.removeAll()\n'):
            self.assertEqual(1, value.count(addition)); value = value.replace(addition, '', 1)
        loop = '''        while true {
            try await acquire(requireIdle: false, transferSlice: true)
            // The resumed slice rechecks on this actor, with no further suspension before TID
            // assignment. A window may have opened while it was resuming from the FIFO.
            if interactiveUses.isEmpty { break }
            release()
        }
'''
        self.assertEqual(1, value.count(loop)); value = value.replace(loop, '        try await acquire(requireIdle: false)\n', 1)
        start, end = value.index('    /// A priority window'), value.index('    private func acquire(')
        value = value[:start] + value[end:]
        value = value.replace('private func acquire(requireIdle: Bool, transferSlice: Bool = false)', 'private func acquire(requireIdle: Bool)')
        value = value.replace('busy || (transferSlice && !interactiveUses.isEmpty)', 'busy')
        value = value.replace('Waiter(id: id, transferSlice: transferSlice, continuation:', 'Waiter(id: id, continuation:')
        release = '''        if terminalError == nil,
           let index = waiters.firstIndex(where: { !$0.transferSlice || interactiveUses.isEmpty }) {
            busy = true
            waiters.remove(at: index).continuation.resume()
'''
        self.assertIn(release, value)
        value = value.replace(release, '''        if terminalError == nil, !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
''')
        self.assertEqual(original, value)
        android = read('app/src/main/java/com/ztransfer/protocol/NikonCamera.kt')
        gate = android.split('suspend fun <T> withTransferSlice(', 1)[1].split('/**', 1)[0]
        self.assertIn('interactiveWaiters.first { it == 0 }', gate)
        self.assertLess(gate.index('mutex.lock()'), gate.index('if (interactiveWaiters.value == 0)'))

    def test_native_bracket_does_not_fall_back_without_priority_and_always_releases_on_ui(self):
        value = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePreviewReadSession.kt')
        body = value.split('internal suspend fun <T> withInteractivePriority(', 1)[1].split('@Throws', 1)[0]
        self.assertLess(body.index('if (granted != true) throw CancellationException'), body.index('block()'))
        self.assertIn('finally {', body)
        self.assertIn('withContext(NonCancellable + uiContext)', body)
        self.assertIn('bridge.endPreviewPriority(sessionId, it)', body)
        connection = read('iosApp/ZTransfer/Network/CameraWiFiConnection.swift')
        bracket = connection.split('private func withInteractivePreviewPriority<T>', 1)[1].split('private func previewCommand', 1)[0]
        self.assertEqual(2, bracket.count('await endInteractivePreview(token)'))
        self.assertNotIn('Task {', bracket)  # Release is awaited on both success and error.

    def test_page_late_registration_returns_its_token_and_cannot_release_next_session(self):
        value = read('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        body = value.split('func beginPreviewPriority(', 1)[1].split('func readFhdPreview(', 1)[0]
        for required in ('previewUse?.session == sessionId', 'previewPriorities.count < 32',
                         'source.beginInteractivePreview()', '!Task.isCancelled',
                         'await source.endInteractivePreview(token)', 'task.cancel()',
                         'await task.value', 'previewPriorities.removeValue(forKey: key)'):
            self.assertIn(required, body)
        for forbidden in ('CameraWiFiConnection(', 'CameraTCPStream(', 'PtpIPCommandSession(', 'sleep('):
            self.assertNotIn(forbidden, body)
        end = value.split('func endPreviewReads(', 1)[1].split('func cancelRequests(', 1)[0]
        self.assertIn('Array(previewPriorities.keys)', end)
        self.assertIn('key.hasPrefix("\\(sessionId):")', end)


if __name__ == '__main__': unittest.main()
