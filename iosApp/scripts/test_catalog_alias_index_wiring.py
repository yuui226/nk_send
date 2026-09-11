"""W03-A source contracts. Native JVM tests execute; Swift interoperability remains Mac-only."""
from pathlib import Path
import subprocess
import unittest
from catalog_alias_index_wiring import CHANGES, previous_catalog_alias_index_source

ROOT = Path(__file__).resolve().parents[2]
CATALOG = 'iosApp/ZTransfer/Network/CameraCatalog.swift'
SCAN = 'shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraCatalogScan.kt'
BASELINE = 'shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraHandleBaseline.kt'
FACADE = 'shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraCatalogReconciliation.kt'
def raw_read(path): return (ROOT/path).read_text(encoding='utf-8')
def read(path):
    from parallel_batch_wiring import previous_parallel_batch_source
    return previous_parallel_batch_source(path, raw_read(path))
def before(path): return subprocess.check_output(['git', 'show', 'e216b1d:' + path], cwd=ROOT).decode('utf-8')

class CatalogAliasIndexWiringTest(unittest.TestCase):
    def test_exact_inverse_preserves_all_prior_scan_and_resolver_bodies(self):
        self.assertEqual({CATALOG, SCAN, BASELINE}, set(CHANGES))
        for path in CHANGES:
            self.assertEqual(before(path), previous_catalog_alias_index_source(path, raw_read(path)))

    def test_android_kernel_and_existing_io_ui_cache_remain_unchanged(self):
        for path in ('app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt',
                     'app/src/main/java/com/ztransfer/protocol/NikonCamera.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/CameraFilePublicationPolicy.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/catalog/CameraCatalogPolicy.kt',
                     'iosApp/ZTransfer/Network/CameraWiFiConnection.swift',
                     'iosApp/ZTransfer/Network/CameraPreviewStore.swift',
                     'iosApp/ZTransfer/UI/OriginalFilesPage.swift',
                     'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift'):
            self.assertEqual(before(path), read(path))

    def test_metadata_index_keeps_hidden_aliases_in_constant_time_access_order(self):
        value = read(SCAN)
        for token in ('private val indexedHandles = ArrayList<Int>()',
                      'indexedObjectCount: Int get() = indexedHandles.size',
                      'indexedHandles.getOrNull(index)?.let(objectInfos::get)',
                      'if (!objectInfos.containsKey(handle)) indexedHandles += handle'):
            self.assertIn(token, value)
        self.assertLess(value.index('if (info == null)'), value.index('indexedHandles += handle'))
        self.assertLess(value.index('if (info.isAssociation)'), value.index('indexedHandles += handle'))
        self.assertLess(value.index('val name = info.fileName'), value.index('indexedHandles += handle'))
        for forbidden in ('objectInfos.values.toList()', 'objectInfos.keys.elementAt(', 'indexedHandles.sort'):
            self.assertNotIn(forbidden, value)

    def test_real_scan_and_new_object_snapshots_carry_all_aliases_without_extra_io(self):
        value = read(CATALOG)
        for token in ('let indexedObjectInfos: [PtpObjectInfo]', '0..<Int(scan.indexedObjectCount)',
                      'scan.indexedObjectInfoAt(index: Int32(index))', 'infos[info.handle] = info; indexedInfos.append(info)',
                      'indexedObjectInfos: indexedInfos', 'indexedObjectInfos: base.indexedObjectInfos + [info]'):
            self.assertIn(token, value)
        self.assertNotIn('scan.objectInfo(handle: file.handle)', value)
        self.assertEqual(before(CATALOG).count('try await source.objectInfo('), value.count('try await source.objectInfo('))
        self.assertEqual(before(CATALOG).count('try await source.newObjectInfo('), value.count('try await source.newObjectInfo('))

    def test_native_removal_facade_delegates_without_reimplementing_row_identity(self):
        value = read(FACADE)
        for token in ('currentHandles?.toSet() ?: return null', 'LinkedHashMap<Int, CameraFileInfo>()',
                      'NewCameraObjectPolicy.publicationFile(info)',
                      'return reconcilePublishedCameraFiles(publishedFiles, current, indexed)'):
            self.assertIn(token, value)
        for forbidden in ('logicalIdentity()', 'sorted', 'android.', 'java.', 'Task', 'CoroutineScope'):
            self.assertNotIn(forbidden, value)

    def test_idle_baseline_removes_only_known_missing_handles_and_requires_success(self):
        value = read(BASELINE).split('fun acceptIdleEnumeration(', 1)[1].split('    /**', 1)[0]
        for token in ('knownHandles ?: return null', 'handles?.toSet() ?: return null',
                      'cameraHandleDelta(previous, current)', 'knownHandles = previous - delta.removed'):
            self.assertIn(token, value)
        self.assertNotIn('knownHandles = current', value)
        self.assertNotIn('delta.added', value)

    def test_guard_rejects_index_loss_and_does_not_hide_unrelated_scan_changes(self):
        for path, old, new in ((CATALOG, 'base.indexedObjectInfos + [info]', '[info]'),
                               (SCAN, 'indexedHandles += handle', 'indexedHandles += 0'),
                               (BASELINE, 'knownHandles = previous - delta.removed', 'knownHandles = current')):
            with self.assertRaises(AssertionError):
                previous_catalog_alias_index_source(path, raw_read(path).replace(old, new))
        current = raw_read(SCAN)
        self.assertEqual(current.count('orders = newestFirstHandleOrders(inputs)'), 1)
        changed = current.replace('orders = newestFirstHandleOrders(inputs)', 'orders = emptyList()')
        with self.assertRaises(AssertionError):
            previous_catalog_alias_index_source(SCAN, changed)

    def test_real_apple_scan_partial_failure_and_idle_baseline_scenarios_are_present(self):
        cases = read('iosApp/ZTransferTests/CameraNetworkTests.swift')
        for name in ('testCatalogCarriesHiddenBackupMetadataInReadOrderForSharedRemovalReconciliation',
                     'testPartialCatalogRetainsPreviousCompleteAliasIndexAndNullQueryCannotDeleteRows',
                     'testNativeIdleBaselineDoesNotInventFirstScanOrConsumeUnresolvedAdds'):
            self.assertIn('func ' + name + '()', cases)
        self.assertIn('values.last?.snapshot.indexedObjectInfos.map', cases)
