from pathlib import Path
import subprocess
import unittest
from photo_viewport_extraction import extract_photo_viewport
from photo_preview_model_extraction import extract_photo_preview_model
from photo_preview_display_extraction import extract_photo_preview_display

ROOT = Path(__file__).resolve().parents[2]
BASE = 'app/src/main/java/com/ztransfer/ui/screen/'
PATHS = [BASE+'PhotoPreview.kt', 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedSinglePhotoPreviewOverlay.kt',
         'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedZoomablePreviewViewport.kt',
         BASE+'PreviewRotationButton.kt', 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPreviewRotationButton.kt']


class PhotoViewportExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        def original(name): return subprocess.run(['git','show','55876fa:'+BASE+name], cwd=ROOT,
            check=True,capture_output=True,text=True,encoding='utf-8').stdout
        cls.photo = original('PhotoPreview.kt'); cls.rotation = original('PreviewRotationButton.kt')
        cls.expected = extract_photo_viewport(cls.photo,cls.rotation)
        cls.expected = (extract_photo_preview_display(extract_photo_preview_model(cls.expected[0])[0])[0],) + cls.expected[1:]

    def test_entire_android_remainder_and_all_shared_bodies_are_exact(self):
        for path, expected in zip(PATHS,self.expected):
            self.assertEqual(expected,(ROOT/path).read_text(encoding='utf-8'),path)

    def test_android_uses_one_shared_viewport_for_full_and_single_previews(self):
        android,single,viewport,rotation,button = self.expected
        self.assertIn('SharedPhotoPreviewPage(',android)
        page=(ROOT/'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPhotoPreviewPage.kt').read_text(encoding='utf-8')
        self.assertIn('SharedZoomablePreviewViewport(',page)
        self.assertIn('SharedZoomablePreviewViewport(',single)
        self.assertNotIn('fun ZoomablePreviewViewport(',android)
        self.assertIn('SharedSinglePhotoPreviewOverlay(bitmap, title, anchorRect, onDismiss',android)
        self.assertIn('BackHandler(enabled, onBack)',android)
        self.assertIn('stringResource(R.string.cd_rotate_photo)',rotation)
        self.assertIn('contentDescription = description()',button)

    def test_gesture_consumption_zoom_keys_rotation_and_transition_timings_are_preserved(self):
        single,viewport=self.expected[1:3]
        for expression in ('remember(stateKey)', 'LaunchedEffect(isCurrent, zoomed)', 'LaunchedEffect(rotationDegrees)',
                           '.pointerInput(imageAspect, zoomEnabled, maximumZoom)', '.pointerInput(imageAspect, zoomEnabled)',
                           'pressed >= 2 || scale > 1.01f', 'if (change.pressed) change.consume()',
                           'max(MAX_ZOOM, oneToOneZoom)', '1f - 0.08f * absSin', 'tween(220)', 'tween(240)'):
            self.assertIn(expression,viewport)
        for expression in ('Motion.overlayExpand','Motion.overlayCollapse','0.74f * progress.value',
                           'transformOrigin = TransformOrigin(', 'rotationDegrees -= 90f', 'detectDragGestures { change, _ -> change.consume() }'):
            self.assertIn(expression,single)

    def test_numeric_and_gesture_mutations_are_not_normalized_away(self):
        for old,new in [('tween(240)','tween(241)'),('pressed >= 2','pressed >= 3'),
                        ('MAX_ZOOM = 4f','MAX_ZOOM = 5f'),('DOUBLE_TAP_ZOOM = 2.5f','DOUBLE_TAP_ZOOM = 2.4f'),
                        ('0.74f * progress.value','0.75f * progress.value')]:
            with self.subTest(old=old):
                try:
                    changed=extract_photo_viewport(self.photo.replace(old,new),self.rotation)
                    changed=(extract_photo_preview_display(extract_photo_preview_model(changed[0])[0])[0],)+changed[1:]
                except ValueError:
                    continue # A changed fixed extraction anchor must fail closed.
                self.assertNotEqual(self.expected,changed)

    def test_platform_math_preserves_android_intrinsic(self):
        android=(ROOT/'shared/src/androidMain/kotlin/com/ztransfer/ui/screen/PreviewPlatform.android.kt').read_text()
        self.assertIn('= Math.toRadians(degrees)',android)
        self.assertEqual(2,self.expected[2].count('previewRadians('))
        for body in self.expected[1:3]:
            for forbidden in ('android.', 'CameraViewModel', 'java.', 'R.string', 'SystemClock'):
                self.assertNotIn(forbidden,body)

    def test_native_real_image_entry_is_bounded_frozen_and_not_a_second_swiftui_zoom(self):
        host=(ROOT/'shared/src/iosMain/kotlin/com/ztransfer/ui/SharedUiController.kt').read_text(encoding='utf-8')
        factory=host[host.index('fun singlePhotoPreview('):host.index('fun originalFiles(')]
        self.assertIn('bytes.usePinned { memcpy(',factory)
        self.assertLess(factory.index('isBoundedSinglePhotoPng(bytes)'),factory.index('Image.makeFromEncoded(bytes)'))
        self.assertLess(factory.index('val bitmap = try'),factory.index('return ComposeUIViewController'))
        self.assertIn('SharedSinglePhotoPreviewOverlay(bitmap',factory)
        swift=(ROOT/'iosApp/ZTransfer/Diagnostics/SharedUiProbeView.swift').read_text(encoding='utf-8')
        self.assertIn('SharedUiController.shared.singlePhotoPreview',swift)
        for gesture in ('MagnificationGesture','DragGesture','rotationEffect','scaleEffect'):
            self.assertNotIn(gesture,swift)
        probe=(ROOT/'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift').read_text(encoding='utf-8')
        self.assertEqual(2,probe.count('try await imageDecoder.singlePhotoPNG('))
        self.assertIn('SharedPhotoProbeRequest(png: png, title: probe.previewStatus)',probe)
        self.assertIn('previewImage = nil; previewPNG = nil',probe)
        self.assertIn('sharedPhotoRequest = nil\n            probe.releasePreviewMemory()',probe)
        self.assertIn('if phase == .background { sharedPhotoRequest = nil; probe.cancel() }',probe)
