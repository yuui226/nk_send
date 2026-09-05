"""Structural contracts only. Real Swift filesystem/concurrency tests remain required on Mac."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ThumbnailDiskWiringTest(unittest.TestCase):
    def test_cache_identity_and_expiry_use_existing_shared_policies_without_new_camera_commands(self):
        native=(ROOT/'shared/src/commonMain/kotlin/com/ztransfer/protocol/NativePreviewPolicy.kt').read_text(encoding='utf-8')
        camera=(ROOT/'iosApp/ZTransfer/Network/CameraWiFiConnection.swift').read_text(encoding='utf-8')
        self.assertIn('cameraThumbnailCacheIdentity(', native)
        self.assertIn('isThumbnailCameraCacheExpired(lastConnectedMs, nowMs)', native)
        self.assertIn('thumbnailCacheKeyMaterial(', native)
        self.assertIn('previewPolicy.cameraKey(info: identity, responderGuid: ack.responderGuidHex', camera)
        self.assertEqual(2, camera.count('operationCode: PtpConstants.shared.GET_DEVICE_INFO'))
        station = camera[camera.index('private func initializeStation'):camera.index('private func pairStation')]
        storage_success = station[station.index('if policy.usableStorage'):station.index('let device =')]
        self.assertIn('prefetchedStorageIDs = ids', storage_success)
        self.assertIn('return', storage_success) # The second pre-existing DeviceInfo is only the storage-failure fallback.
        self.assertIn('identity = nil', camera) # Standard STA does not add a DeviceInfo round trip for caching.

    def test_filesystem_is_owned_by_existing_preview_actor_and_shared_across_all_consumers(self):
        store=(ROOT/'iosApp/ZTransfer/Network/CameraPreviewStore.swift').read_text(encoding='utf-8')
        probe=(ROOT/'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift').read_text(encoding='utf-8')
        self.assertIn('private var disk: CameraThumbnailDiskCache?', store)
        self.assertIn('disk?.read(key: identity)', store)
        self.assertIn('disk.write(result, key: identity)', store)
        self.assertIn('previews: previews)', probe)
        self.assertIn('await previews.openDiskCache', probe)
        self.assertEqual(1, probe.count('for await snapshot in queue.updates'))
        self.assertEqual(2, probe.count('await previews.close()'))
        self.assertIn('allowedThumbnailKeys = []', store)
        self.assertIn('guard !closed else { throw CameraStreamError.closed }', store)

    def test_reconciliation_requires_complete_nonraced_catalog_and_rejects_late_reinsertion(self):
        catalog=(ROOT/'iosApp/ZTransfer/Network/CameraCatalog.swift').read_text(encoding='utf-8')
        store=(ROOT/'iosApp/ZTransfer/Network/CameraPreviewStore.swift').read_text(encoding='utf-8')
        self.assertIn('let fillScan = await previews?.beginCatalogScan()', catalog)
        self.assertIn('await previews?.finishCatalogScan(fillScan, snapshot: result)', catalog)
        self.assertIn('await previews?.finishCatalogScan(fillScan, snapshot: nil)', catalog)
        self.assertIn('snapshot.connectionID == connectionID', store)
        self.assertIn('snapshot.metadataComplete, !snapshot.changedWhileScanning', store)
        self.assertIn('allowedThumbnailKeys = keys', store)
        self.assertIn('let result, let disk, allowedThumbnailKeys?.contains(identity) != false', store)

    def test_cache_never_uses_original_folder_or_recursive_delete_and_validates_links_first(self):
        cache=(ROOT/'iosApp/ZTransfer/Storage/CameraThumbnailDiskCache.swift').read_text(encoding='utf-8')
        self.assertNotIn('Originals', cache)
        self.assertNotIn('removeItem(at: root)', cache)
        self.assertIn('guard name == ".last_connected" || Self.isImageName(name) || Self.isTemporaryName(name)', cache)
        self.assertIn('if try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty', cache)
        self.assertIn('options: .withoutOverwriting', cache)
        self.assertIn('data.count <= Self.maximumBytes, Self.validImage(data)', cache)
        self.assertIn('fresh.removeAllCachedResourceValues()', cache)
        self.assertLess(cache.index('fresh.resourceValues(forKeys: [.isSymbolicLinkKey])'), cache.index('fresh.resourceValues(forKeys: [.isDirectoryKey])'))
