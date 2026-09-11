"""W01 wiring checks; shared tests run on Windows, fake-source XCTest must run on Mac."""
from pathlib import Path
import subprocess
import unittest
from handle_baseline_wiring import CHANGES, previous_handle_baseline_source
from new_object_policy_wiring import previous_new_object_policy_source

ROOT = Path(__file__).resolve().parents[2]
CATALOG = 'iosApp/ZTransfer/Network/CameraCatalog.swift'
CORE = 'shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraHandleBaseline.kt'
def read(path): return previous_new_object_policy_source(path, (ROOT/path).read_text(encoding='utf-8'))
def before(path): return subprocess.check_output(['git', 'show', '42abf5b:' + path], cwd=ROOT).decode('utf-8')

class HandleBaselineWiringTest(unittest.TestCase):
    def test_old_catalog_restores_exactly_and_android_shared_policies_are_unchanged(self):
        self.assertEqual({CATALOG}, set(CHANGES))
        self.assertEqual(before(CATALOG), previous_handle_baseline_source(CATALOG, (ROOT/CATALOG).read_text(encoding='utf-8')))
        for path in ('app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/catalog/CameraCatalogPolicy.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/catalog/NativeCameraCatalogScan.kt',
                     'iosApp/ZTransfer/Network/CameraWiFiConnection.swift',
                     'iosApp/ZTransfer/Network/CameraOriginalQueue.swift'):
            self.assertEqual(before(path), read(path))

    def test_baseline_commits_after_complete_same_generation_enumeration_before_metadata(self):
        value = read(CATALOG)
        markers = ('var enumeratedHandles: [Int32] = []', 'for index in 0..<Int(scan.storageCount)',
                   'guard scan.addHandles(', 'enumeratedHandles.append(contentsOf: handles)',
                   'guard scan.begin()', 'let enumerated = await source.snapshot()',
                   'guard enumerated.phase == .ready, enumerated.connectionID == before.connectionID',
                   'let handleDelta = handleBaseline.acceptEnumeration(', 'while true {',
                   'info = try await source.objectInfo(')
        positions = [value.index(marker) for marker in markers]
        self.assertEqual(sorted(positions), positions)
        gate = value.split('let enumerated = await source.snapshot()', 1)[1].split('let handleDelta', 1)[0]
        self.assertIn('try Task.checkCancellation()', gate)
        self.assertIn('before.connectionID == source.connectionID', value)
        self.assertIn('private let handleBaseline = NativeCameraHandleBaseline()', value)
        self.assertIn('func refresh(detectNewHandles: Bool = false)', value)

    def test_metadata_and_publication_remain_separate_from_raw_handle_delta(self):
        value = read(CATALOG)
        self.assertIn('handleDelta: handleDelta)', value)
        self.assertIn('if result.metadataComplete { latest = result }', value)
        self.assertNotIn('enqueueNewMedia', value)
        core = read(CORE)
        for token in ('handles.toSet()', 'cameraHandleDelta(it, current)',
                      'CameraHandleDelta(emptySet(), emptySet())', 'knownHandles = current',
                      'if (detectNewHandles) delta else CameraHandleDelta(emptySet(), delta.removed)'):
            self.assertIn(token, core)
        for forbidden in ('metadataComplete', 'fileName', 'Task', 'UUID', 'CameraWiFiConnection'):
            self.assertNotIn(forbidden, core)

    def test_guard_rejects_generation_bypass_and_does_not_hide_old_failure_changes(self):
        raw = (ROOT/CATALOG).read_text(encoding='utf-8')
        for old,new in (('enumerated.connectionID == before.connectionID', 'true'),
                        ('detectNewHandles: Bool = false', 'detectNewHandles: Bool = true')):
            with self.assertRaises(AssertionError):
                previous_handle_baseline_source(CATALOG, raw.replace(old,new))
        publication = 'if result.metadataComplete && !result.changedWhileScanning { latest = result }'
        self.assertIn(publication, raw)  # Never let a vanished mutation target become a no-op.
        changed = raw.replace(publication, 'latest = result')
        # W02-B's adjacent wakeup hunk now guards this original publication condition too.
        with self.assertRaises(AssertionError):
            previous_handle_baseline_source(CATALOG, changed)
        changed = raw.replace('else if !scan.publishNext() { break }', 'else if !scan.publishNext() { continue }')
        # Full-file fingerprints now reject unrelated mutations before historical inversion.
        with self.assertRaises(AssertionError):
            previous_handle_baseline_source(CATALOG, changed)
