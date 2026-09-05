"""The optional Native hook must not replace any of the original Android sync coordinator."""
from pathlib import Path
import subprocess
import unittest
from preview_async_enqueue_wiring import add_async_preview_enqueue, remove_async_preview_enqueue

ROOT = Path(__file__).resolve().parents[2]
PATH = 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPhotoPreviewOverlay.kt'


class AsyncPreviewQueueWiringTest(unittest.TestCase):
    def test_removing_enumerated_hook_restores_complete_verified_sync_coordinator(self):
        original = subprocess.run(['git', 'show', 'ec109df:' + PATH], cwd=ROOT,
            check=True, capture_output=True, text=True, encoding='utf-8').stdout
        actual = (ROOT / PATH).read_text(encoding='utf-8')
        self.assertEqual(original, remove_async_preview_enqueue(actual))
        self.assertEqual(actual, add_async_preview_enqueue(original))

    def test_android_omits_opt_in_and_both_original_callbacks_stay_synchronous(self):
        android = (ROOT / 'app/src/main/java/com/ztransfer/ui/screen/PhotoPreview.kt').read_text(encoding='utf-8')
        shared = (ROOT / PATH).read_text(encoding='utf-8')
        self.assertNotIn('onTransferAsync', android)
        self.assertIn('onTransferAsync: (suspend (List<CameraFileInfo>) -> Int)? = null', shared)
        self.assertIn('if (!enqueue()) return', shared)
        self.assertIn('currentOnTransfer(file)', shared)
        self.assertIn('currentOnTransferBurst(collection.files)', shared)
        self.assertEqual(2, shared.count('if (currentOnTransferAsync != null)'))

    def test_page_dispose_and_live_identity_guard_before_reusing_original_flight(self):
        shared = (ROOT / PATH).read_text(encoding='utf-8')
        self.assertIn('DisposableEffect(asyncQueueAcceptance, currentItem?.key, closing)', shared)
        self.assertIn('onDispose { asyncQueueAcceptance.cancel() }', shared)
        self.assertIn('onDispose { asyncQueueAcceptance.close() }', shared)
        self.assertIn('previewItems.getOrNull(pagerState.currentPage)?.key == key', shared)
        hook = shared.split('fun awaitPreviewQueueAcceptance(', 1)[1].split('fun enqueueFromPreview(', 1)[0]
        self.assertLess(hook.index('settleQueuePhoto()'), hook.index('gate.request('))
        self.assertIn('startPreviewQueueFlight(bitmap, rotation, burstFiles) { true }', hook)
        self.assertNotIn('currentOnTransfer(', hook)

    def test_mutating_sync_animation_or_fallback_does_not_get_hidden_by_projection(self):
        shared = (ROOT / PATH).read_text(encoding='utf-8')
        projected = remove_async_preview_enqueue(shared)
        for old, new in [('if (!enqueue()) return', 'if (enqueue()) return'),
                         ('PREVIEW_QUEUE_FLIGHT_DURATION_MS = 560', 'PREVIEW_QUEUE_FLIGHT_DURATION_MS = 561'),
                         ('queueFlightProgress = value', 'queueFlightProgress = 0f')]:
            self.assertNotEqual(projected, remove_async_preview_enqueue(shared.replace(old, new)))
