"""Current production contracts for the 50-part batch, not a Swift compiler substitute."""
from pathlib import Path
import subprocess
import unittest
from parallel_batch_wiring import CHANGES, previous_parallel_batch_source

ROOT = Path(__file__).resolve().parents[2]
CATALOG = 'iosApp/ZTransfer/Network/CameraCatalog.swift'
WIRE = 'iosApp/ZTransfer/Network/CameraWiFiConnection.swift'
PROBE = 'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'
PAGE = 'iosApp/ZTransfer/UI/OriginalFilesPage.swift'
AUTO = 'iosApp/ZTransfer/Network/CameraAutomaticTransferCoordinator.swift'
PREFS = 'iosApp/ZTransfer/Configuration/BrowsePreferencesStore.swift'

def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', 'ca00994:' + path], cwd=ROOT).decode('utf-8')

class ParallelBatchWiringTest(unittest.TestCase):
    def test_reviewed_inverses_restore_entire_prebatch_production_files(self):
        self.assertEqual(len(CHANGES), 17)
        for path in CHANGES:
            self.assertEqual(before(path), previous_parallel_batch_source(path, read(path)), path)

    def test_android_product_and_packaging_scripts_are_untouched(self):
        paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', 'ca00994', 'app', 'dist', 'dist-debug'], cwd=ROOT).decode().splitlines()
        changed = set(subprocess.check_output(['git', 'diff', 'ca00994', '--name-only', '--', 'app', 'dist', 'dist-debug'], cwd=ROOT).decode().splitlines())
        self.assertTrue(paths)
        self.assertFalse(changed, changed)

    def test_one_event_observer_owns_catalog_and_real_automatic_admission(self):
        source = read(PROBE)
        self.assertEqual(1, source.count('for await state in connection.updates'))
        self.assertIn('await sessionCatalog.receiveEvents(batch)', source)
        self.assertIn('onChange: { [weak self] snapshot in await self?.receiveCatalogChange(snapshot) }', source)
        self.assertIn('automaticTransfer?.receive(addition, transfer: filesPage?.model.currentTransferPreferences())', source)
        self.assertIn('filesPage?.publishAddition(snapshot)', source)
        self.assertIn('let first = try await sessionCatalog.refresh()', source)
        loop = source.split('for await state in connection.updates', 1)[1]
        self.assertLess(loop.index('sessionAutomatic.close()'), loop.index('await previews.setConnected'))

    def test_shared_controls_use_real_coordinator_same_document_and_explicit_recovery(self):
        page = read(PAGE)
        for token in ('NativeAutomaticTransferSettingsPlatform', 'model.automaticTransfer.attach(platform: self)',
                      'automaticTransfer?.setEnabled(enabled)', 'automaticTransfer?.resetAfterUserConfirmation()'):
            self.assertIn(token, page)
        overlay = read('shared/src/commonMain/kotlin/com/ztransfer/ui/NativePhotoSettingsOverlay.kt')
        for token in ('SettingsTextKey.auto_transfer_new_media', 'model.automaticTransfer::setEnabled',
                      'enabled = !automatic.failed', 'if (confirmTransferReset) AlertDialog',
                      'model.automaticTransfer.resetAfterConfirmation()', 'model.reloadTransferPreferences()'):
            self.assertIn(token, overlay)
        prefs = read(PREFS).split('final class BrowsePreferencesStore', 1)[0]
        self.assertEqual(1, prefs.count('static let key ='))
        self.assertIn('autoTransferNewMedia: Bool?', prefs)
        self.assertIn('document.autoTransferNewMedia ?? false', prefs)
        self.assertIn('guard let automatic = readAutomatic() else { return false }', prefs)

    def test_catalog_failures_cannot_publish_empty_deletions_and_wire_gate_is_reused(self):
        source = read(CATALOG)
        for token in ('NativeCameraCatalogReconciliation.shared.reconcile', 'handleBaseline.acceptIdleEnumeration',
                      'indexedInfos: base.indexedObjectInfos', 'pendingChange?.token == request.token',
                      'before.eventRevision == after.eventRevision', 'after.eventRevision <= (receivedEventRevision ?? 0)',
                      'allowsCatalogReconciliation()', 'catch is CameraOperationError { return 2_000 }'):
            self.assertIn(token, source)
        self.assertIn('if batch.requiresRescan { requestChange(full: true); return }', source)
        self.assertIn('if result.changedWhileScanning { requestChange(full: true) }', source)
        self.assertIn('[Int32(0x4004), 0x4005, 0x4007, 0x400C]', source)
        self.assertIn('changeWorker?.cancel()', source)
        wire = read(WIRE).split('private func catalogMetadata(', 1)[1].split('/// A confirmed miss', 1)[0]
        self.assertIn('previewCommand(', wire)
        self.assertIn('await self.backgroundReadsAllowed()', wire)
        self.assertIn('return await permitted()', wire)
        self.assertIn('guard let data = result.payload else', wire)
        session = read('iosApp/ZTransfer/Network/PtpIPCommandSession.swift')
        self.assertIn('backgroundAdmission', session)

    def test_automatic_path_uses_queue_admission_not_download_or_second_destination(self):
        source = read(AUTO)
        for token in ('mayAutomaticallyTransfer', 'transfer ?? preferences.read()',
                      'addition.snapshot.connectionID == connectionID', 'let file = addition.newMedia',
                      'queue.enqueueNewMedia', 'worker?.cancel()', 'func close()'):
            self.assertIn(token, source)
        for token in ('CameraOriginalQueue(', '.download(', 'ProviderOriginalStore(', 'UserDefaults('):
            self.assertNotIn(token, source)
        queue = read('iosApp/ZTransfer/Network/CameraOriginalQueue.swift').split('func enqueueNewMedia(', 1)[1].split('    func ', 1)[0]
        self.assertIn('guard !Task.isCancelled, enabled, destination != nil', queue)
        self.assertIn('core.enqueueNewMedia', queue)

    def test_exif_uses_existing_bounded_walk_and_preserves_legacy_read_entrypoints(self):
        source = read('shared/src/commonMain/kotlin/com/ztransfer/preview/PreviewExifRationalReader.kt')
        self.assertIn('captureMetadata: Boolean = false', source)
        self.assertIn('if (captureMetadata) PreviewExifSupplement() else null', source)
        self.assertIn('fun readMetadata(', source)
        self.assertIn('maximumReadBytes = 512 * 1024', source)
        bridge = read('shared/src/iosMain/kotlin/com/ztransfer/preview/NativePreviewExifRationalBridge.kt')
        self.assertIn('readMetadata(source, size, header = false)', bridge)
        self.assertIn('readMetadata(source, size, header = true)', bridge)
        reader = read('iosApp/ZTransfer/Storage/PreviewExifReader.swift')
        self.assertIn('metadata([:], locale: locale, rawRationals: rationals)', reader)

    def test_new_apple_scenarios_are_registered_but_not_claimed_executed(self):
        project = read('iosApp/ZTransfer.xcodeproj/project.pbxproj')
        for filename, minimum in (('CatalogEventReconciliationTests.swift', 25),
                                  ('AutomaticTransferTests.swift', 16), ('ExifCompatibilityTests.swift', 9),
                                  ('CameraWorkspaceTests.swift', 11), ('CameraDiscoveryProfileTests.swift', 16),
                                  ('MediaPreviewCompatibilityTests.swift', 17)):
            self.assertIn('path = ' + filename, project)
            self.assertGreaterEqual(read('iosApp/ZTransferTests/' + filename).count('func test'), minimum)

    def test_exact_inverse_rejects_admission_and_lifecycle_bypass(self):
        for path, token in ((CATALOG, 'pendingChange?.token == request.token'),
                            (WIRE, 'await self.backgroundReadsAllowed()'),
                            (PROBE, 'sessionAutomatic.close(); sessionReady = false')):
            with self.assertRaises(AssertionError):
                previous_parallel_batch_source(path, read(path).replace(token, 'true'))

    def test_product_and_diagnostics_borrow_the_same_session_owner(self):
        content = read('iosApp/ZTransfer/ContentView.swift')
        self.assertIn('@StateObject private var workspace = CameraWorkspaceBridge()', content)
        self.assertIn('CameraWorkspace(bridge: workspace)', content)
        self.assertIn('CameraHandshakeProbeView(probe: workspace.session)', content)
        workspace = read('iosApp/ZTransfer/UI/CameraWorkspace.swift')
        for token in ('let session: CameraHandshakeProbe', 'session.connectProduct(',
                      'session.openSharedFiles()', 'session.openSharedQueue()', 'session.cancel()'):
            self.assertIn(token, workspace)
        for token in ('CameraWiFiConnection(', 'CameraOriginalQueue(', 'PtpIPCommandSession('):
            self.assertNotIn(token, workspace)

    def test_history_never_trusts_an_ap_or_guesses_bonjour_address(self):
        self.assertIn('guard stationMode, service == nil, let responderGUID else { return }', read(PROBE))
        discovery = read('iosApp/ZTransfer/Network/CameraDiscoveryCoordinator.swift')
        for token in ('selectableServices.first(where: { $0.id == id })',
                      'expectedResponderGUID: entry.responderGUID', 'self.generation == current',
                      'profileIssue, snapshot.message', 'observer?.cancel()'):
            self.assertIn(token, discovery)
        profile = read('iosApp/ZTransfer/Network/StationProfileStore.swift')
        self.assertIn('guard Data(document.initiator.utf8) == identity else', profile)
        self.assertIn('try currentDocument()', profile)

    def test_full_resolution_decode_retains_route_and_checks_representation(self):
        decoder = read('iosApp/ZTransfer/Storage/PreviewImageDecoder.swift')
        for token in ('CFGetTypeID(number) != CFBooleanGetTypeID()', 'value.isFinite',
                      'value.rounded(.towardZero) == value', 'multipliedReportingOverflow',
                      'private func withDataSource<T>', 'try autoreleasepool'):
            self.assertIn(token, decoder)
        original = decoder.split('func originalBitmapPNG(', 1)[1].split('func queueThumbnailPNG(', 1)[0]
        self.assertIn('CGImageSourceCreateImageAtIndex', original)
        self.assertNotIn('CGImageSourceCreateThumbnailAtIndex', original)
        self.assertNotIn('honorOrientation: true', original)

    def test_idle_reconciliation_replays_retained_scan_candidates_with_existing_fence(self):
        catalog = read(CATALOG)
        self.assertIn('await publishScanAdditions(updated, previousFiles: base.files)', catalog)
        replay = catalog.split('private func publishScanAdditions(', 1)[1].split('private func wakeResolver()', 1)[0]
        for token in ('!needsEventRescan', 'latest?.publicationRevision == result.publicationRevision',
                      'scanCatchupHandles.remove(addition.info.handle)'):
            self.assertIn(token, replay)
        with self.assertRaises(AssertionError):
            previous_parallel_batch_source(CATALOG, catalog.replace(
                'await publishScanAdditions(updated, previousFiles: base.files)', '// lost replay'))

    def test_failed_disable_cancels_admission_before_disk_write_and_latches_session_off(self):
        automatic = read(AUTO)
        setter = automatic.split('func setEnabled(', 1)[1].split('func preferencesDidChange()', 1)[0]
        self.assertLess(setter.index('disabledForSession = true'), setter.index('preferences.saveAutomatic(enabled)'))
        self.assertLess(setter.index('invalidatePending()'), setter.index('preferences.saveAutomatic(enabled)'))
        self.assertIn('if enabled { disabledForSession = false }', setter)
        self.assertIn('return stored && !disabledForSession', automatic)
        self.assertIn('self.mayAutomaticallyTransfer, self.pendingIndex < self.pending.count', automatic)

    def test_initial_catalog_reuse_checks_current_connection_then_keeps_explicit_refresh(self):
        host = read(PROBE).split('func openSharedFiles(', 1)[1].split('func pauseQueue()', 1)[0]
        self.assertLess(host.index('await catalog.snapshot()'), host.index('await connection.snapshot()'))
        self.assertIn('apConnection === connection, self.catalog === catalog', host)
        self.assertIn('page.loadInitialCatalog(initialCatalog, state: state)', host)
        page = read(PAGE)
        initial = page.split('func loadInitialCatalog(', 1)[1].split('func refresh()', 1)[0]
        for token in ('state.connectionID == connectionID', 'value.revision == state.eventRevision',
                      'value.metadataComplete, !value.changedWhileScanning', 'refreshOriginals(', 'refresh()'):
            self.assertIn(token, initial)
        explicit = page.split('func refresh()', 1)[1].split('private func refreshOriginals(', 1)[0]
        self.assertIn('try await self.catalog.refresh()', explicit)

    def test_backup_catchup_uses_existing_shared_identity_not_filename_only(self):
        catalog = read(CATALOG)
        helper = catalog.split('private static func sameLogicalIdentity(', 1)[1].split('private func wakeResolver()', 1)[0]
        self.assertIn('!NewCameraObjectPolicy.shared.isNew(files: [saved], handle: differentHandle, info: candidate)', helper)
        self.assertIn('scanCatchupMedia.values.contains { Self.sameLogicalIdentity($0, file) }', catalog)
        self.assertIn('scanCatchupMedia.filter { !Self.sameLogicalIdentity($0.value, media) }', catalog)

if __name__ == '__main__': unittest.main()
