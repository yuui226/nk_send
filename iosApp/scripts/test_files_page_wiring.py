"""Read-only wiring guards; these do not substitute for Swift/Kotlin Native compilation."""
from pathlib import Path
import unittest

class FilesPageWiringTest(unittest.TestCase):
    def test_filter_uses_full_catalog_stores_real_local_calendar_and_synchronous_reveal(self):
        root=Path(__file__).resolve().parents[2]
        bridge=(root/'iosApp/ZTransfer/UI/OriginalFilesPage.swift').read_text(encoding='utf-8')
        self.assertIn('value.storageIDs.enumerated()', bridge)
        self.assertIn('snapshot.setStorageIds(values: cameraStores)', bridge)
        self.assertIn('Calendar(identifier: .gregorian)', bridge)
        self.assertIn('calendar.timeZone = timeZone', bridge)
        page=(root/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt').read_text(encoding='utf-8')
        self.assertIn('LaunchedEffect(state.files, state.hasSnapshot, state.scanning)', page)
        self.assertIn('delay(600); filterRevealWindow = false', page)
        self.assertIn('filterRevealWindow = true // Set synchronously', page)
        self.assertIn('SharedFilesQueueWorkspace(queueVisible = showQueue', page)
        self.assertIn('allowRemoteThumbnails = connected && preview == null && !showQueue', page)
    def test_native_grid_uses_original_defaults_and_clears_expansion_when_disabled(self):
        root=Path(__file__).resolve().parents[2]
        s=(root/'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt').read_text(encoding='utf-8')
        self.assertIn('val layout by model.layout.collectAsState()', s)
        self.assertIn('val columns = layout.columns', s)
        self.assertIn('val collapseBursts = layout.collapseBursts', s)
        controls=(root/'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedSettingsControls.kt').read_text(encoding='utf-8')
        self.assertIn('PHOTO_COLUMN_OPTIONS = listOf(2, 3, 4)', controls)
        self.assertIn('NativePhotoSettingsOverlay(model, layout, settingsText, frozenAnchor, appearance)', s)
        self.assertIn('LaunchedEffect(collapseBursts, state.bursts, state.hasSnapshot, state.scanning)', s)
        self.assertIn('} else emptySet()', s)
        self.assertIn('tapToPreview = layout.tapToPreview', s)

    def test_files_entry_is_not_hidden_until_the_first_queue_task(self):
        root=Path(__file__).resolve().parents[2]
        s=(root/'iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift').read_text(encoding='utf-8')
        self.assertLess(s.index('Button("打开共享文件浏览（真实目录）")'), s.index('if let queue = probe.queueSnapshot'))
        self.assertEqual(1, s.count('for await snapshot in queue.updates'))
        self.assertIn('filesPage?.publishQueue(snapshot)', s)
        self.assertIn('filesPage?.setConnected(state.phase == .ready)', s)

    def test_bridge_uses_real_catalog_and_existing_queue_without_another_consumer(self):
        root=Path(__file__).resolve().parents[2]
        s=(root/'iosApp/ZTransfer/UI/OriginalFilesPage.swift').read_text(encoding='utf-8')
        self.assertIn('try await self.catalog.refresh(onBatch:', s)
        self.assertIn('await self?.acceptBatch(value, sequence: sequence)', s)
        self.assertIn('await self.queue.enqueueCatalog', s)
        self.assertIn('SharedUiController.shared.originalFiles', s)
        self.assertNotIn('for await', s)
        self.assertNotIn('queue.stop', s)
        self.assertNotIn('queue.updates', s)
        self.assertLess(s.index('guard accepted else'), s.index('Dictionary(uniqueKeysWithValues:'))
        self.assertIn(': model.finishScan(sequence: sequence, snapshot: snapshot)', s)
