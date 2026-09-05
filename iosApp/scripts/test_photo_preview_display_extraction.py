from pathlib import Path
import subprocess
import unittest
from photo_viewport_extraction import extract_photo_viewport
from photo_preview_model_extraction import extract_photo_preview_model
from photo_preview_display_extraction import extract_photo_preview_display
from histogram_extraction import extract_histogram_button
from photo_preview_session_extraction import extract_photo_preview_session
from thumbnail_grid_extraction import section

ROOT=Path(__file__).resolve().parents[2]
BASE='app/src/main/java/com/ztransfer/ui/screen/'
SHARED='shared/src/commonMain/kotlin/com/ztransfer/ui/screen/'


class PhotoPreviewDisplayExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        def original(name):return subprocess.run(['git','show','55876fa:'+BASE+name],cwd=ROOT,check=True,
            capture_output=True,text=True,encoding='utf-8').stdout
        cls.source=extract_photo_preview_model(extract_photo_viewport(original('PhotoPreview.kt'),original('PreviewRotationButton.kt'))[0])[0]
        cls.parts=extract_photo_preview_display(cls.source)

    def test_complete_original_page_and_all_shared_bodies_are_exact(self):
        paths=[BASE+'PhotoPreview.kt']+[SHARED+s for s in ['SharedPhotoPreviewPage.kt','SharedPhotoPreviewBurst.kt',
            'SharedPhotoPreviewDetails.kt','PhotoPreviewDisplayPlatform.kt']]
        for path,body in zip(paths,self.parts):
            if path == BASE+'PhotoPreview.kt':
                body = extract_photo_preview_session(extract_histogram_button(body)[0])[0]
            self.assertEqual(body,(ROOT/path).read_text(encoding='utf-8'),path)

    def test_entire_parent_preview_coordinator_changes_only_video_constant_reference(self):
        start='internal fun PhotoPreviewOverlay(';end='@Composable\ninternal fun SinglePhotoPreviewOverlay('
        expected=section(self.source,start,end).replace('in VIDEO_EXTENSIONS','in PREVIEW_VIDEO_EXTENSIONS')
        self.assertEqual(expected,section(self.parts[0],start,end))
        self.assertNotIn('private val VIDEO_EXTENSIONS',self.parts[0])
        self.assertIn('val PREVIEW_VIDEO_EXTENSIONS = setOf(".mov", ".mp4")',self.parts[1])

    def test_fhd_reveal_uses_original_monotonic_time_not_animation_frames(self):
        android,page=self.parts[:2]
        for text in ('FHD_REVEAL_DURATION_MS = 300L','FHD_REVEAL_FRAME_MS = 16L','LaunchedEffect(fhdBitmap)',
                     'val startedAt = uptimeMillis()', 'val elapsed = uptimeMillis() - startedAt',
                     'FastOutSlowInEasing.transform(linearProgress)','delay(FHD_REVEAL_FRAME_MS)',
                     'val effectiveFhdAlpha = if (thumb == null) 1f else fhdAlpha'):
            self.assertIn(text,page)
        self.assertNotIn('withFrameNanos',page)
        self.assertIn('uptimeMillis = { SystemClock.uptimeMillis() }',android)
        self.assertIn('thumb != null && (fhdBitmap == null || effectiveFhdAlpha < 1f)',page)

    def test_original_thumbnail_keys_no_thumb_gate_and_video_metadata_are_retained(self):
        android,page=self.parts[:2]
        for text in ('remember(file.handle)', 'LaunchedEffect(file.handle, loadEnabled, allowRemoteThumbnailFallback)',
                     'if (loadEnabled && thumbnail == null && !noThumb)',
                     'else if (allowRemoteThumbnailFallback) noThumb = true',
                     'LaunchedEffect(displayBitmap, isCurrent)', 'zoomEnabled = !isVideo && displayBitmap != null',
                     'val metadata = text.videoMetadata(file)'):
            self.assertIn(text,page)
        self.assertIn('cameraViewModel.loadThumbnail(file = file, allowRemote = allowRemote)',android)
        self.assertIn('fileSize = file.size, captureDate = file.captureDate',android)
        self.assertIn('overFourGbLabel = stringResource(R.string.video_size_over_4gb)',android)

    def test_burst_ghost_keeps_cache_only_path_and_original_stack(self):
        android,_,burst=self.parts[:3]
        ghost=section(android,'private fun PreviewBurstQueueFlightGhost(', '@Composable\nprivate fun BurstCollectionExpandButton(')
        self.assertIn('loadEnabled = false',ghost)
        self.assertIn('SharedPreviewBurstStack(files, remember(cameraViewModel)',android)
        self.assertIn('transfersBusy = false',android)
        for text in ('files.take(3).reversed()', 'minOf(maxWidth * 0.72f, maxHeight * 0.46f, 360.dp)',
                     'loadEnabled = loadEnabled','content.Photo(', 'content.Badge(', 'stackSize * 0.07f + 6.dp',
                     '1f + 0.012f * motion', '.pointerInput(collection.id)', 'LaunchedEffect(isCurrent)'):
            self.assertIn(text,burst)
        self.assertNotIn('loadThumbnail',burst)

    def test_exif_geometry_and_resource_reads_remain_in_original_composition_positions(self):
        details=self.parts[3]
        fields=['exif.aperture','exif.shutterSpeed','exif.iso','exif.exposureCompensation','exif.focalLength']
        self.assertEqual(sorted(details.index(x) for x in fields),[details.index(x) for x in fields])
        for text in ('rememberTextMeasurer(cacheSize = 4)', 'remember(text, availableWidthPx, baseStyle)',
                     'fontSize = 13.sp, lineHeight = 18.sp','fontSize = 12.sp, lineHeight = 17.sp',
                     'fontSize = 11.sp, lineHeight = 16.sp','overflow = TextOverflow.Clip',
                     'val description = text.navigationDescription(expand)','contentDescription = text.transferDescription()'):
            self.assertIn(text,details)
        for body in self.parts[1:]:
            for forbidden in ('android.', 'CameraViewModel', 'SystemClock', 'R.string', 'java.'):
                self.assertNotIn(forbidden,body)

    def test_numeric_keys_and_loading_mutations_are_detected_not_normalized(self):
        for old,new in [('FHD_REVEAL_DURATION_MS = 300L','FHD_REVEAL_DURATION_MS = 301L'),
                        ('files.take(3).reversed()','files.take(2).reversed()'),
                        ('if (loadEnabled && thumbnail == null && !noThumb)','if (thumbnail == null && !noThumb)'),
                        ('rememberTextMeasurer(cacheSize = 4)','rememberTextMeasurer(cacheSize = 5)'),
                        ('fontSize = 13.sp, lineHeight = 18.sp','fontSize = 14.sp, lineHeight = 18.sp')]:
            with self.subTest(old=old):
                self.assertIn(old,self.source)
                try:changed=extract_photo_preview_display(self.source.replace(old,new))
                except ValueError:continue
                self.assertNotEqual(self.parts,changed)
