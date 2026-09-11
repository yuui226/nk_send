"""Source wiring guards. Swift scheduling and socket behavior still require the XCTest suite on Mac."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]
def source(path): return (ROOT/path).read_text(encoding='utf-8')

class ThumbnailFillWiringTest(unittest.TestCase):
    def test_shared_queue_is_the_only_sort_retry_and_lane_implementation(self):
        native=source('shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeThumbnailFillQueue.kt')
        actor=source('iosApp/ZTransfer/Network/CameraPreviewStore.swift')
        self.assertIn('ThumbnailFillQueue<CameraFileInfo>()', native)
        for call in ('queue.seed(copied, range)', 'queue.updatePriorityRange(next)', 'queue.retryFailed()', 'queue.returnToFront(request.file, request.revision)'):
            self.assertIn(call,native)
        self.assertIn('private let fill = NativeThumbnailFillQueue()',actor)
        self.assertIn('fillWorker == nil',actor)
        self.assertNotIn('Task.sleep',actor)
        self.assertNotIn('.sorted',actor)
        self.assertIn('observed != fillWake',actor)

    def test_transfers_and_dates_come_from_connection_host_not_page_lifetime(self):
        host=source('iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift')
        android=source('app/src/main/java/com/ztransfer/MainActivity.kt')
        page=source('iosApp/ZTransfer/UI/OriginalFilesPage.swift')
        self.assertIn('val transfersBusy = transferState.isTransferring',android)
        self.assertIn('await previews.setTransfersBusy(snapshot.running)',host)
        self.assertEqual(1,host.count('for await snapshot in queue.updates'))
        self.assertIn('await previews.startBackgroundFill',host)
        self.assertIn('await previews.beginForegroundUse()',host)
        self.assertIn('await previews.endForegroundUse(foreground)',host)
        self.assertIn('BrowsePreferencesStore.nextUpdateRevision()',page)
        self.assertNotIn('previews.close()',page)

    def test_background_admission_runs_after_lock_and_before_tid_or_wire_side_effects(self):
        session=source('iosApp/ZTransfer/Network/PtpIPCommandSession.swift')
        start=session.index('func execute('); end=session.index('func close()',start); body=session[start:end]
        self.assertLess(body.index('try await acquire'),body.index('await backgroundAdmission()'))
        self.assertLess(body.index('await backgroundAdmission()'),body.index('lastTransactionId &+= 1'))
        self.assertLess(body.index('await backgroundAdmission()'),body.index('        do {'))
        camera=source('iosApp/ZTransfer/Network/CameraWiFiConnection.swift')
        self.assertIn('phase == .ready && !downloadActive',camera)
        self.assertIn('backgroundAdmission: admission',camera)

    def test_scan_token_disk_gate_and_foreground_token_prevent_stale_resume(self):
        actor=source('iosApp/ZTransfer/Network/CameraPreviewStore.swift')
        for expression in ('scanToken == token','revision > priorityRevision','foregroundUses.isEmpty','disk != nil && !diskWritesBlocked',
                           'let use = beginForegroundUse()', 'defer { endForegroundUse(use) }','fill.isCurrent(request: request)'):
            self.assertIn(expression,actor)
        self.assertNotIn('fillWorker?.cancel()',actor)
