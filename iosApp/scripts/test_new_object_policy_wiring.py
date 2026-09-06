"""Verify the bounded Android extraction without claiming that the iOS resolver is wired yet."""
from pathlib import Path
import subprocess
import unittest
from new_object_policy_wiring import CHANGES, previous_new_object_policy_source

ROOT = Path(__file__).resolve().parents[2]
ANDROID = 'app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt'
POLICY = 'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/NewCameraObjectPolicy.kt'
def read(path):
    from new_object_resolver_wiring import previous_new_object_resolver_source
    return previous_new_object_resolver_source(path, (ROOT/path).read_text(encoding='utf-8'))
def before(path): return subprocess.check_output(['git', 'show', '8484b35:' + path], cwd=ROOT).decode('utf-8')
def between(value, start, end): return value.split(start, 1)[1].split(end, 1)[0]

class NewObjectPolicyWiringTest(unittest.TestCase):
    def test_full_android_owner_restores_after_only_enumerated_delegation(self):
        self.assertEqual({ANDROID}, set(CHANGES))
        self.assertEqual(before(ANDROID), previous_new_object_policy_source(ANDROID, read(ANDROID)))
        for path in ('app/src/main/java/com/ztransfer/protocol/NikonCamera.kt',
                     'app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt',
                     'shared/src/commonMain/kotlin/com/ztransfer/viewmodel/CameraFilePublicationPolicy.kt',
                     'iosApp/ZTransfer/Network/CameraCatalog.swift',
                     'iosApp/ZTransfer/Network/CameraWiFiConnection.swift'):
            self.assertEqual(before(path), read(path))

    def test_android_calls_shared_decisions_without_changing_io_retry_or_emit_order(self):
        value = read(ANDROID)
        for token in ('NewCameraObjectPolicy.shouldResolve(handle, knownHandles.takeIf { hasKnownBaseline }, _state.value.files)',
                      'NewCameraObjectPolicy.publish(state.files, handle, info)',
                      'if (published === state.files) state else state.copy(files = published)',
                      'NewCameraObjectPolicy.isNew(previousState.files, handle, info)',
                      'NewCameraObjectPolicy.retryDelayMs(pending.attempts)',
                      'NEW_OBJECT_COALESCE_MS = NewCameraObjectPolicy.COALESCE_MS',
                      'NEW_OBJECT_RESOLVE_BATCH_SIZE = NewCameraObjectPolicy.RESOLVE_BATCH_SIZE',
                      'NEW_OBJECT_RESOLVE_MAX_ATTEMPTS = NewCameraObjectPolicy.RESOLVE_MAX_ATTEMPTS'):
            self.assertIn(token, value)
        self.assertEqual(between(before(ANDROID), '    private suspend fun resolveNewCameraObject(', '    private suspend fun publishNewCameraObject('),
                         between(value, '    private suspend fun resolveNewCameraObject(', '    private suspend fun publishNewCameraObject('))
        self.assertEqual(between(before(ANDROID), '        if (knownHandlesCamera === cam) knownHandles += handle', '    /** Resolve a newly announced direct-STA'),
                         between(value, '        if (knownHandlesCamera === cam) knownHandles += handle', '    /** Resolve a newly announced direct-STA'))

    def test_shared_decisions_reuse_existing_identity_membership_and_exact_timing(self):
        value = read(POLICY)
        for token in ('COALESCE_MS = 90L', 'RESOLVE_BATCH_SIZE = 16', 'RESOLVE_MAX_ATTEMPTS = 5',
                      'longArrayOf(180L, 360L, 720L, 1_400L)', 'backoffMs[attempts - 1]',
                      'files.indexOfFirst', 'it.handle == handle || it.logicalIdentity() == info.logicalIdentity()',
                      'mergeStorageMembership(existing, info)', 'if (merged === existing) files'):
            self.assertIn(token, value)
        for forbidden in ('android.', 'java.', 'swift', 'CoroutineScope', 'SystemClock', 'Thread', 'delay(', 'Task'):
            self.assertNotIn(forbidden, value)

    def test_guards_reject_mutated_shared_calls_and_leave_unrelated_owner_changes_visible(self):
        raw = read(ANDROID)
        for old,new in (('NewCameraObjectPolicy.publish(state.files, handle, info)', 'state.files'),
                        ('NewCameraObjectPolicy.RESOLVE_MAX_ATTEMPTS', '99')):
            with self.assertRaises(AssertionError):
                previous_new_object_policy_source(ANDROID, raw.replace(old,new))
        changed = raw.replace('const val KEEPALIVE_INTERVAL_MS = 10_000L', 'const val KEEPALIVE_INTERVAL_MS = 1L')
        self.assertNotEqual(before(ANDROID), previous_new_object_policy_source(ANDROID, changed))
