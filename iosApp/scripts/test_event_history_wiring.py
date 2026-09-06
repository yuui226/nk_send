"""Source guards only. Ordered fake-socket XCTest cases still require Apple execution."""
from pathlib import Path
import subprocess
import unittest
from event_history_wiring import CHANGES, previous_event_history_source
from handle_baseline_wiring import previous_handle_baseline_source

ROOT = Path(__file__).resolve().parents[2]
CONNECTION = 'iosApp/ZTransfer/Network/CameraWiFiConnection.swift'
TESTS = 'iosApp/ZTransferTests/CameraNetworkTests.swift'

def read(path): return previous_handle_baseline_source(path, (ROOT/path).read_text(encoding='utf-8'))
def before(path): return subprocess.check_output(['git', 'show', '5bedb81:' + path], cwd=ROOT).decode('utf-8')
def between(value, start, end): return value.split(start, 1)[1].split(end, 1)[0]

class EventHistoryWiringTest(unittest.TestCase):
    def test_only_event_history_changes_in_the_entire_connection_owner(self):
        self.assertEqual({CONNECTION}, set(CHANGES))
        self.assertEqual(before(CONNECTION), previous_event_history_source(CONNECTION, read(CONNECTION)))
        for path in ('iosApp/ZTransfer/Network/PtpIPChannel.swift',
                     'iosApp/ZTransfer/Network/CameraOriginalQueue.swift',
                     'iosApp/ZTransfer/Network/CameraCatalog.swift',
                     'app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/protocol/PtpIpProtocolCodec.kt'):
            self.assertEqual(before(path), read(path))

    def test_real_event_receiver_keeps_shared_decoder_and_bounded_append_before_wakeup(self):
        value = read(CONNECTION)
        receive = between(value, '    private func startEvents()', '    private func startKeepalive()')
        self.assertIn('let decoded = PtpIPChannel.event(packet.payload)', receive)
        self.assertIn('await self?.receivedEvent(decoded)', receive)
        record = between(value, '    private func receivedEvent(', '    /// A download-wide reservation')
        for token in ('phase == .opening || phase == .ready', 'eventRevision < UInt64.max',
                      'eventRevision += 1', 'code: decoded.code', 'transactionID: decoded.transactionId',
                      'firstParameter: decoded.firstParameter',
                      'eventRecords.removeFirst(eventRecords.count - Self.eventHistoryLimit)'):
            self.assertIn(token, record)
        self.assertLess(record.index('eventRecords.append('), record.index('publish()'))
        self.assertIn('static let eventHistoryLimit = 256', value)
        self.assertIn('eventRecords.removeAll(keepingCapacity: false)', between(value, '    private func finish(', '    private func publish()'))
        self.assertEqual(before(CONNECTION).count('AsyncStream('), value.count('AsyncStream('))

    def test_cursor_read_checks_generation_gap_and_phase_without_io_or_mutation(self):
        value = between(read(CONNECTION), '    func events(after ', '    private func receivedEvent(')
        for token in ('try requirePhase(.ready)', 'cursor.connectionID == connectionID',
                      'cursor.revision <= eventRevision', 'cursor.revision >= $0.revision - 1',
                      'events: [], requiresRescan: true', 'eventRecords.filter { $0.revision > cursor.revision }'):
            self.assertIn(token, value)
        for forbidden in ('await ', 'Task {', 'remove', 'append', 'session.', 'channel.', 'notifications.'):
            self.assertNotIn(forbidden, value)

    def test_guards_reject_loss_generation_and_unrelated_transaction_mutations(self):
        raw = read(CONNECTION)
        for old, new in (('cursor.connectionID == connectionID,', ''),
                         ('events: [], requiresRescan: true', 'events: [], requiresRescan: false'),
                         ('eventRecords.append(CameraEventRecord', '_ = CameraEventRecord')):
            with self.assertRaises(AssertionError):
                previous_event_history_source(CONNECTION, raw.replace(old, new))
        changed = raw.replace('initialTransactionId: stationMode ? -1 : 0', 'initialTransactionId: 0')
        self.assertNotEqual(before(CONNECTION), previous_event_history_source(CONNECTION, changed))
        cases = read(TESTS)
        for token in ('testEventHistoryPreservesOrderedDecodedFieldsAcrossAPAndStationWithoutAnotherStreamConsumer',
                      'testEventHistoryOverflowReportsGapAndNeverReturnsAnIncompleteTailAsComplete',
                      'testEventHistoryRejectsForeignFutureCancelledAndClosedReads',
                      'testEventHistoryIgnoresPingAndMalformedEventButKeepsTheFollowingCompleteEvent'):
            self.assertIn('func ' + token + '()', cases)
