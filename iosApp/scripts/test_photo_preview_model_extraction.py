from pathlib import Path
import subprocess
import unittest
from photo_viewport_extraction import extract_photo_viewport
from photo_preview_model_extraction import extract_photo_preview_model,extract_preview_tests,MIGRATED_TESTS

ROOT=Path(__file__).resolve().parents[2]
BASE='app/src/main/java/com/ztransfer/ui/screen/'
def original(path):
    return subprocess.run(['git','show','55876fa:'+path],cwd=ROOT,check=True,capture_output=True,text=True,encoding='utf-8').stdout


class PhotoPreviewModelExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=extract_photo_viewport(original(BASE+'PhotoPreview.kt'),original(BASE+'PreviewRotationButton.kt'))[0]
        cls.android,cls.shared=extract_photo_preview_model(cls.source)

    def test_entire_android_remainder_and_shared_model_match_baseline(self):
        self.assertEqual(self.android,(ROOT/BASE/'PhotoPreview.kt').read_text(encoding='utf-8'))
        self.assertEqual(self.shared,(ROOT/'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedPhotoPreviewModel.kt').read_text(encoding='utf-8'))

    def test_every_moved_test_preserves_body_values_and_remaining_android_tests(self):
        for name,(sharedname,_) in MIGRATED_TESTS.items():
            android_path='app/src/test/java/com/ztransfer/ui/screen/'+name+'.kt'
            android,shared=extract_preview_tests(original(android_path),name)
            self.assertEqual(android,(ROOT/android_path).read_text(encoding='utf-8'))
            self.assertEqual(shared,(ROOT/('shared/src/commonTest/kotlin/com/ztransfer/ui/screen/'+sharedname+'.kt')).read_text(encoding='utf-8'))
        self.assertEqual(9,sum(len(methods) for _,methods in MIGRATED_TESTS.values()))

    def test_date_format_route_and_actual_io_coordinator_are_not_rewritten(self):
        for start,end in [('internal fun localOriginalPreviewRoute(', '/** PTP DateTime'),
                          ('/** PTP DateTime','/**\n * 全屏预览层')]:
            # Removed pure blocks are the only omissions between these anchors.
            old=self.source[self.source.index(start):self.source.index(end)]
            current=self.android[self.android.index(start):self.android.index(end)]
            if start.startswith('internal'):
                old=old[:old.index('internal fun <T> isLocalPreviewResolved(')]
            else:
                old=old[:old.index('/** 预览分页模型')]
            self.assertEqual(old,current)
        anchor='internal fun PhotoPreviewOverlay('
        self.assertEqual(self.source[self.source.index(anchor):],self.android[self.android.index(anchor):])
        for forbidden in ('android.', 'java.', 'CameraViewModel', 'formatFileSize(', 'Uri'):
            self.assertNotIn(forbidden,self.shared)

    def test_source_snapshot_order_and_member_return_rules_are_preserved(self):
        for text in ('put(item.file.handle, sourceFor(item.file))','put(file.handle, sourceFor(file))',
                     'if (isPreviewBurstExpanded(items, collectionPage, collection.id)) return items',
                     'items.getOrNull(collectionPage + 1)', 'it.burstId == burstId', 'it in 0 until memberPage',
                     'isCurrent && fhdUnavailable && exifFinished'):
            self.assertIn(text,self.shared)

    def test_changes_to_order_thresholds_and_fallback_cannot_hide_in_extraction(self):
        for old,new in [('items.drop(collectionPage + 1)','items.drop(collectionPage + 2)'),
                        ('0 until memberPage','0..memberPage'),
                        ('* 0.22f','* 0.23f'),
                        ('isCurrent && fhdUnavailable && exifFinished','isCurrent && fhdUnavailable')]:
            with self.subTest(old=old):
                self.assertNotEqual(self.shared,extract_photo_preview_model(self.source.replace(old,new))[1])
