from pathlib import Path
import subprocess
import unittest
from signal_pill_extraction import extract_signal_pill


class SignalPillExtractionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = subprocess.run(['git', 'show', '55876fa:app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt'],
            cwd=Path(__file__).resolve().parents[2], check=True, capture_output=True, text=True, encoding='utf-8').stdout
        cls.android, cls.shared = extract_signal_pill(cls.original)

    def test_android_flow_collector_and_callback_stay_original(self):
        def collector(source):
            start = source.index('private fun FileListSignalPill(')
            end = source.index('/**\n * 连接状态毛玻璃按钮', start)
            return source[start:end]
        self.assertEqual(collector(self.original), collector(self.android))
        self.assertIn('onStaDisconnectedClick = onStaDisconnectedClick', self.android)
        self.assertIn('context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))', self.android)
        self.assertNotIn('allowUnknownRssi = true', self.android)

    def test_shared_rendering_has_no_android_settings_resources_and_no_fabricated_rssi(self):
        for value in ('LocalContext', 'Intent(', 'stringResource(', 'com.ztransfer.R'):
            self.assertNotIn(value, self.shared)
        self.assertIn('val r = rssi ?: -999', self.shared) # original fallback retained only for original branches
        self.assertIn('unknownSignal -> SignalPillMode.WIFI_UNKNOWN', self.shared)
        self.assertIn('visible = expanded && online && !staMode && !unknownSignal', self.shared)
        self.assertIn('else if (!online && !usbMode) onOpenWifiSettings()', self.shared)

    def test_geometry_timing_and_palette_changes_are_not_normalized_away(self):
        for before, after in [('tween(550, easing', 'tween(551, easing'),
                              ('Color(0xFFA8E7BC)', 'Color(0xFFA8E7BD)'),
                              ('unit * 0.11f', 'unit * 0.12f')]:
            self.assertNotEqual(extract_signal_pill(self.original.replace(before, after))[1], self.shared)
