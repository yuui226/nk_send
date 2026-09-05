"""Source preservation/wiring checks only; these do NOT execute UIKit or compile Swift."""
from pathlib import Path
import subprocess
import unittest
from appearance_wiring import without_appearance_page

ROOT = Path(__file__).resolve().parents[2]
BASE = 'ac79211'
UI = 'shared/src/commonMain/kotlin/com/ztransfer/ui/'

def read(path): return (ROOT / path).read_text(encoding='utf-8')
def before(path): return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode('utf-8')
def replace_once(value, old, new):
    assert value.count(old) == 1, old
    return value.replace(old, new, 1)

class AppearanceWiringTest(unittest.TestCase):
    def test_both_swift_pages_only_borrow_app_appearance_without_changing_camera_queue_or_close(self):
        for name in ('OriginalFilesPage', 'OriginalQueuePage'):
            path = f'iosApp/ZTransfer/UI/{name}.swift'
            self.assertEqual(before(path), without_appearance_page(read(path)))
            self.assertNotIn('appearance.close()', read(path))

    def test_native_files_only_adds_appearance_arguments_feedback_and_failure_display(self):
        path = UI + 'NativeOriginalFilesPage.kt'
        expected = before(path)
        for old, new in (
            ('    settingsText: NativeSettingsPageText,\n', '    settingsText: NativeSettingsPageText,\n    appearance: NativeAppearanceModel,\n'),
            ('    val preferencesFailed by model.preferencesFailed.collectAsState()\n',
             '    val preferencesFailed by model.preferencesFailed.collectAsState()\n    val appearanceState by appearance.state.collectAsState()\n'),
            ('rememberHaptics(true)', 'rememberHaptics(appearanceState.hapticsEnabled)'),
            ('if (preferencesFailed) Text', 'if (preferencesFailed || appearanceState.preferencesFailed) Text'),
            ('hapticsEnabled = true, transfersBusy', 'hapticsEnabled = appearanceState.hapticsEnabled, transfersBusy'),
            ('suggestedDate = suggestedDate, hapticsEnabled = true,', 'suggestedDate = suggestedDate, hapticsEnabled = appearanceState.hapticsEnabled,'),
            ('NativePhotoSettingsOverlay(model, layout, settingsText, frozenAnchor)',
             'NativePhotoSettingsOverlay(model, layout, settingsText, frozenAnchor, appearance)'),
        ):
            expected = replace_once(expected, old, new)
        self.assertEqual(expected, read(path)) # Snapshot/preview/scroll/queue/cache/transfer calls all preserved.

    def test_native_controllers_keep_existing_sources_and_diagnostics_while_observing_live_language(self):
        path = 'shared/src/iosMain/kotlin/com/ztransfer/ui/SharedUiController.kt'
        expected = before(path)
        for model in ('NativeFilesPageModel', 'NativeQueuePageModel'):
            expected = replace_once(expected, f'model: {model}, languageTag: String,', f'model: {model}, appearance: NativeAppearanceModel,')
        for old in ('            DisposableEffect(images) { onDispose { images.close() } }\n            SharedZTransferTheme {',
                    '    fun originalQueue(model: NativeQueuePageModel, appearance: NativeAppearanceModel, onBack: () -> Unit): UIViewController =\n        ComposeUIViewController {\n            SharedZTransferTheme {'):
            new = old.replace('            SharedZTransferTheme {',
                '            val appearanceState by appearance.state.collectAsState()\n'
                '            val languageTag = appearanceState.resolvedLanguage\n            NativeAppTheme(appearanceState) {')
            expected = replace_once(expected, old, new)
        expected = replace_once(expected, '                    settingsText = NativeSettingsTextCatalog.forLanguage(languageTag),\n',
            '                    settingsText = NativeSettingsTextCatalog.forLanguage(languageTag),\n                    appearance = appearance,\n')
        self.assertEqual(expected, read(path))

    def test_all_five_original_appearance_controls_have_live_model_callbacks(self):
        host = read(UI + 'NativePhotoSettingsOverlay.kt')
        for token in ('SharedAppearanceSettingsCard(', 'appearance.setThemeName(it.name)', 'onLanguage = appearance::setLanguage',
                      'appearance.setSkinName(it.name)', 'onHaptics = appearance::setHapticsEnabled',
                      'onKeepScreenOn = appearance::setKeepScreenOn, close = close',
                      'layout.tapToPreview, appearanceState.hapticsEnabled, text'):
            self.assertIn(token, host)
        self.assertNotIn('SharedTransferDirectorySettingsCard(', host)
        self.assertNotIn('rememberHaptics(true)', read(UI + 'NativeOriginalFilesPage.kt'))

    def test_actual_material_palette_and_background_use_same_shared_implementations(self):
        theme = read(UI + 'NativeAppTheme.kt')
        for token in ('rememberButtonTexturePalette(appearance.skin, isZTransferDarkTheme(appearance.theme))',
                      'LocalButtonTexturePalette provides palette', 'SharedZTransferTheme(appearance.theme, appearance.skin)',
                      'background(rememberAppBackgroundBrush())'):
            self.assertIn(token, theme)
        for path in ('app/src/main/java/com/ztransfer/ui/theme/Theme.kt', UI + 'theme/SharedTheme.kt',
                     UI + 'theme/SkinTexture.kt', UI + 'screen/SharedSettingsControls.kt'):
            self.assertEqual(before(path), read(path))

    def test_apple_owner_has_independent_storage_synchronous_lifecycle_and_no_page_owned_idle_timer(self):
        owner = read('iosApp/ZTransfer/Configuration/AppAppearanceSettings.swift')
        for token in ('"ztransfer.appearance.preferences"', 'data.count <= 16 * 1024', 'value.version == 1',
                      'guard read() != nil else { return false }', 'UIApplication.shared.isIdleTimerDisabled = $0',
                      'UIApplication.willResignActiveNotification', 'UIApplication.didEnterBackgroundNotification',
                      'notifications.removeObserver(self)', 'model.close()', 'guard !started, !closed else { return }'):
            self.assertIn(token, owner)
        lifecycle = owner.split('@objc private func didBecomeActive', 1)[1].split('@objc nonisolated private func localeChanged', 1)[0]
        self.assertNotIn('Task', lifecycle); self.assertNotIn('async', lifecycle)
        self.assertNotIn('Locale.setDefault', owner)
        root = read('iosApp/ZTransfer/ContentView.swift')
        self.assertIn('.preferredColorScheme(appearance.colorScheme)', root)
        self.assertIn('.onAppear { appearance.start() }', root)

    def test_defaults_match_the_actual_android_preferences_not_transient_initial_ui(self):
        android = read('app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt')
        for token in ('prefs.getBoolean("haptics_enabled", true)', 'prefs.getBoolean("keep_screen_on", true)',
                      'SkinPreset.entries.firstOrNull { it.name == storedSkinName } ?: SkinPreset.TITANIUM'):
            self.assertIn(token, android)
        native = read(UI + 'NativeAppearanceModel.kt')
        self.assertIn('if (skinName == null) SkinPreset.FROSTED_GLASS', native)
        self.assertIn('else SkinPreset.entries.firstOrNull { it.name == skinName } ?: SkinPreset.TITANIUM', native)
        self.assertIn('NativeAppearancePreferences(null, "system", null, true, true)', native)

if __name__ == '__main__': unittest.main()
