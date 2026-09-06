"""W02-B exact-source/routing checks, NOT Swift compilation or concurrency execution."""
from pathlib import Path
import subprocess
import unittest
from new_object_resolver_wiring import CHANGES, previous_new_object_resolver_source

ROOT = Path(__file__).resolve().parents[2]
CATALOG = 'iosApp/ZTransfer/Network/CameraCatalog.swift'
CONNECTION = 'iosApp/ZTransfer/Network/CameraWiFiConnection.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'
PAGE = 'iosApp/ZTransfer/UI/OriginalFilesPage.swift'
PREVIEWS = 'iosApp/ZTransfer/Network/CameraPreviewStore.swift'
def read(path): return (ROOT/path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', '9a65a60:' + path], cwd=ROOT).decode('utf-8')
def between(value, start, end): return value.split(start, 1)[1].split(end, 1)[0]

class NewObjectResolverWiringTest(unittest.TestCase):
    def test_exact_reviewed_hunks_restore_all_previous_production_owners(self):
        self.assertEqual(7, len(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_new_object_resolver_source(path, read(path)))
        for path in ('app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt',
                     'app/src/main/java/com/ztransfer/protocol/NikonCamera.kt',
                     'iosApp/ZTransfer/Network/CameraOriginalQueue.swift',
                     'shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraCatalogScan.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/CameraFilePublicationPolicy.kt',
                     'iosApp/ZTransfer/Network/PtpIPCommandSession.swift'):
            self.assertEqual(before(path), read(path))

    def test_existing_single_connection_observer_forwards_history_without_auto_enqueuing(self):
        value = read(PROBE)
        self.assertEqual(1, value.count('for await state in connection.updates'))
        self.assertEqual(1, value.count('connection.events(after: eventCursor)'))
        for token in ('CameraEventCursor(connectionID: connection.connectionID, revision: 0)',
                      'eventCursor = batch.cursor', 'await sessionCatalog.receiveEvents(batch)',
                      'onAddition: { [weak self] addition in await self?.receiveCatalogAddition(addition) }'):
            self.assertIn(token, value)
        self.assertEqual(2, value.count('await sessionCatalog.close()'))
        callback = between(value, '    private func receiveCatalogAddition(', '    nonisolated static func inspectAPSession(')
        self.assertIn('apConnection?.connectionID == addition.snapshot.connectionID', callback)
        self.assertIn('filesPage?.publishAddition(addition.snapshot)', callback)
        self.assertNotIn('enqueue', callback)

    def test_new_metadata_command_uses_the_existing_post_gate_pre_transaction_admission(self):
        value = between(read(CONNECTION), '    func newObjectInfo(', '    /// A confirmed miss')
        for token in ('PtpConstants.shared.GET_OBJECT_INFO', 'limit: 64 * 1024, admission: permitted',
                      'guard result.code == PtpConstants.shared.RESPONSE_OK',
                      'PtpIPChannel.objectInfo(handle: handle, payload: data)', 'CameraOperationError.malformedDataset'):
            self.assertIn(token, value)
        session = read('iosApp/ZTransfer/Network/PtpIPCommandSession.swift')
        self.assertLess(session.index('try await acquire(requireIdle: requireIdle)'), session.index('if let backgroundAdmission'))
        self.assertLess(session.index('if let backgroundAdmission'), session.index('lastTransactionId &+= 1'))

    def test_worker_uses_shared_rules_and_rechecks_generation_token_and_socket_revision(self):
        value = read(CATALOG)
        for token in ('handleBaseline.shouldResolve(', 'handleBaseline.hasSnapshot',
                      'NewCameraObjectPolicy.shared.COALESCE_MS', 'NewCameraObjectPolicy.shared.RESOLVE_BATCH_SIZE',
                      'NewCameraObjectPolicy.shared.RESOLVE_MAX_ATTEMPTS', 'NewCameraObjectPolicy.shared.retryDelayMs(',
                      'NewCameraObjectPolicy.shared.publicationFile(', 'NewCameraObjectPolicy.shared.isNew(',
                      'NewCameraObjectPolicy.shared.publish(', 'NewCameraObjectPolicy.shared.automaticMedia(',
                      'handleBaseline.recordPublished(', 'pendingOrder.append(handle)',
                      'pendingOrder.filter', 'scanGeneration == generation', 'pendingObjects[handle]?.token == token',
                      'await previews.allowsObjectResolution()', 'state.eventRevision > (receivedEventRevision ?? 0)',
                      'info.handle == handle', 'catch CameraStreamError.operationInProgress { continue }',
                      'resolverFailed = true; needsEventRescan = true', 'await previews?.reconcile(updated)'):
            self.assertIn(token, value)
        events = between(value, '    func receiveEvents(', '    func close()')
        self.assertIn('batch.cursor.connectionID == source.connectionID', events)
        self.assertIn('batch.cursor.revision <= receivedEventRevision', events)
        self.assertIn('batch.requiresRescan { needsEventRescan = true; return }', events)
        self.assertIn('pendingObjects.removeValue(forKey: handle)', events)
        self.assertNotIn('await ', events)
        self.assertNotIn('enqueueNewMedia', value)

    def test_ui_and_thumbnail_publication_reject_older_snapshots_and_close_owned_work(self):
        value = read(PAGE)
        for token in ('value.publicationRevision >= lastCatalogPublication',
                      'pendingCatalogPublication.publicationRevision >= value.publicationRevision',
                      'self.refreshTask == nil && self.commands.isEmpty',
                      'catalogPublicationTask?.cancel(); catalogPublicationTask = nil; pendingCatalogPublication = nil'):
            self.assertIn(token, value)
        publish = between(value, '    func publishAddition(', '    func enqueue(')
        self.assertIn('self.model.beginScan()', publish)
        self.assertNotIn('catalog.refresh', publish)
        self.assertIn('snapshot.publicationRevision >= catalogPublicationRevision', read(PREVIEWS))

    def test_guard_mutations_are_detected_and_old_unrelated_work_is_not_hidden(self):
        for path, old, new in ((CATALOG, 'scanGeneration == generation', 'true'),
                               (CONNECTION, 'limit: 64 * 1024, admission: permitted', 'limit: 64 * 1024'),
                               (PAGE, 'value.publicationRevision >= lastCatalogPublication', 'true'),
                               (PREVIEWS, 'snapshot.publicationRevision >= catalogPublicationRevision', 'true')):
            with self.assertRaises(AssertionError):
                previous_new_object_resolver_source(path, read(path).replace(old, new))
        raw = read(CONNECTION).replace('initialTransactionId: stationMode ? -1 : 0', 'initialTransactionId: 0')
        self.assertNotEqual(before(CONNECTION), previous_new_object_resolver_source(CONNECTION, raw))

    def test_apple_scenarios_are_registered_as_source_not_claimed_as_execution(self):
        value = read('iosApp/ZTransferTests/CameraNetworkTests.swift')
        for name in ('testNewObjectEventsIgnoreInitialOldInvalidAndDuplicateHandlesAndMergeBackups',
                     'testNewObjectBusyRetriesAreBoundedAndSuccessfulRetryPublishesOnce',
                     'testNewObjectWaitsForInitialBaselineAndForegroundPreviewWithoutConsumingAttempts',
                     'testNewObjectScanSupersedesHeldMetadataAndDoesNotReportAnOldFileAsNew',
                     'testNewObjectRemovalAndReadditionInvalidatesTheHeldToken',
                     'testNewObjectSocketObserverLagDoesNotPublishBeforeRemovalIsForwarded',
                     'testNewObjectGapAndForeignConnectionCannotStartReadsAndCloseDropsHeldResults',
                     'testNewObjectTransportFailureStopsResolverUntilExplicitSuccessfulScan',
                     'testRealNewObjectCommandChecksAdmissionWithoutSendingOrConsumingTransaction',
                     'testRealNewObjectCommandPreservesBusyMalformedAndFollowingValidTransactions',
                     'testFilesAdditionWaitsForScanAndRejectsOlderPublicationWithoutStartingQueue',
                     'testNewObjectPublicationUpdatesThumbnailAdmissionAndRejectsStaleCacheSnapshot'):
            self.assertIn('func ' + name + '()', value)
