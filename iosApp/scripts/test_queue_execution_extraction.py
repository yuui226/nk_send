from pathlib import Path
import subprocess
import unittest
from queue_execution_extraction import extract_queue_execution


class QueueExecutionExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = subprocess.run(['git', 'show', '55876fa:app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt'],
            cwd=Path(__file__).resolve().parents[2], check=True, capture_output=True, text=True, encoding='utf-8').stdout
        cls.android, cls.shared = extract_queue_execution(cls.original)

    def test_adapter_preserves_callbacks_and_everything_outside_button(self):
        anchor = '/** 与状态胶囊同材质的顶部队列操作按钮，不跟随可选按钮皮肤。 */'
        self.assertEqual(self.android.split(anchor)[0], self.original.split(anchor)[0])
        self.assertEqual(self.android.split('@Composable\nfun QueuePill(')[1], self.original.split('@Composable\nfun QueuePill(')[1])
        self.assertIn('onStart = onStart, onPause = onPause, modifier = modifier', self.android)
        self.assertIn('control = control, pauseRequested = pauseRequested, startEnabled = startEnabled', self.android)

    def test_original_interaction_and_accessibility_without_android_resources(self):
        self.assertIn('val enabled = control == QueueExecutionControl.PAUSE || startEnabled', self.shared)
        self.assertIn('onClick = if (control == QueueExecutionControl.START) onStart else onPause', self.shared)
        self.assertIn('pauseRequested -> pauseScheduledDescription', self.shared)
        for forbidden in ('stringResource(', 'R.string', 'LocalContext', 'com.ztransfer.R'):
            self.assertNotIn(forbidden, self.shared)

    def test_numeric_changes_are_detected_and_changed_icon_is_rejected(self):
        for old, new in [('0.92f', '0.91f'), ('tween(180)', 'tween(181)'), ('32f * pressScale', '33f * pressScale')]:
            self.assertNotEqual(extract_queue_execution(self.original.replace(old, new))[1], self.shared)
        with self.assertRaises(ValueError):
            extract_queue_execution(self.original.replace('TransferQueuePauseIcon = Icons.Default.Pause', 'TransferQueuePauseIcon = Icons.Default.Stop'))
