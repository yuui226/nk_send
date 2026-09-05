"""Native preview source wiring guards, not Swift compilation or runtime evidence."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class NativePreviewReadWiringTest(unittest.TestCase):
    def test_product_fhd_cannot_request_thumbnail_fallback(self):
        store = source("iosApp/ZTransfer/Network/CameraPreviewStore.swift")
        product = store.split("func fhd(info:", 1)[1].split("func cachedThumbnail", 1)[0]
        self.assertIn("load(info: info, fhd: true)", product)
        self.assertNotIn("fhd: false", product)
        self.assertIn("defer { endForegroundUse(use) }", product)
        diagnostic = store.split("func preview(info:", 1)[1].split("private func load", 1)[0]
        self.assertIn("fhd: false", diagnostic)

    def test_opening_and_flight_cache_lookup_has_no_io_on_miss(self):
        store = source("iosApp/ZTransfer/Network/CameraPreviewStore.swift")
        cached = store.split("func cachedThumbnail", 1)[1].split("func preview", 1)[0]
        for forbidden in ("await", "try ", "Task {", "load(", "disk."):
            self.assertNotIn(forbidden, cached)
        self.assertIn('cache["thumb:\\(identity)"]', cached)
        self.assertIn("allowedThumbnailKeys?.contains(identity) != false", cached)

    def test_product_orientation_and_edge_follow_original_android(self):
        decoder = source("iosApp/ZTransfer/Storage/PreviewImageDecoder.swift")
        product = decoder.split("func fhdPreviewPNG", 1)[1].split("private func encodePNG", 1)[0]
        self.assertIn("maximumPixelSize: 1920, honorOrientation: false", product)
        self.assertIn("maximumBytes: 20 * 1024 * 1024", product)
        self.assertIn("honorOrientation: Bool = true", decoder)
        android = source("app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt")
        fhd = android.split("suspend fun loadFhdPreview(", 1)[1].split("\n    }", 1)[0]
        self.assertIn("honorExifOrientation = false", fhd)
        self.assertIn("MAX_FHD_PREVIEW_EDGE = 1_920", android)

    def test_cancellation_stays_on_ui_and_rejects_duplicate_or_stale_callbacks(self):
        session = source("shared/src/commonMain/kotlin/com/ztransfer/ui/NativePreviewReadSession.kt")
        for required in ("withContext(uiContext)", "withContext(NonCancellable + uiContext)",
                         "pending[request] === continuation", "continuation.isActive",
                         "currentFile?.invoke(file) == true", "pending.size >= 32",
                         "if (!completed) bridge.cancelPreviewRead(sessionId, request)",
                         "owner = null; currentFile = null"):
            self.assertIn(required, session)
        self.assertLess(session.index("pending[request] = continuation"), session.index("bridge.readFhdPreview("))

    def test_bridge_waits_for_paired_foreground_use_and_retains_cancelled_slots_until_drained(self):
        bridge = source("iosApp/ZTransfer/UI/OriginalFilesPage.swift")
        read = bridge.split("func readFhdPreview", 1)[1].split("func cancelPreviewRead", 1)[0]
        self.assertLess(read.index("await use.task.value"), read.index("self.previews.fhd(info: info)"))
        self.assertEqual(2, read.count("filesByHandle[file.handle] == file"))
        self.assertIn("defer { self.previewRequests.removeValue(forKey: key) }", read)
        self.assertIn("previewRequests.count < 32", read)
        cancel = bridge.split("func cancelPreviewRead", 1)[1].split("func endPreviewReads", 1)[0]
        self.assertIn("?.cancel()", cancel)
        self.assertNotIn("removeValue", cancel)
        end = bridge.split("func endPreviewReads", 1)[1].split("func cancelRequests", 1)[0]
        self.assertIn("use.session == sessionId", end)
        self.assertIn("await previews.endForegroundUse(token)", end)
        for forbidden in ("queue.updates", "CameraWiFiConnection(", "previews.close()", "queue.stop"):
            self.assertNotIn(forbidden, bridge)

    def test_image_boundary_bulk_copies_once_and_checks_length_before_allocation(self):
        bridge = source("shared/src/iosMain/kotlin/com/ztransfer/ui/NativePreviewImageBridge.kt")
        self.assertLess(bridge.index("data.length < 33uL"), bridge.index("ByteArray("))
        self.assertEqual(1, bridge.count("memcpy("))
        self.assertIn("return ownedFhdPreviewPng(bytes)", bridge)
        session = source("shared/src/commonMain/kotlin/com/ztransfer/ui/NativePreviewReadSession.kt")
        self.assertIn("width !in 1..1920 || height !in 1..1920", session)

    def test_model_reuses_original_index_and_releases_only_preview_before_parent_cleanup(self):
        model = source("shared/src/commonMain/kotlin/com/ztransfer/ui/NativeFilesPageModel.kt")
        self.assertIn("originalIndex.localLocator(file, folder = null)", model)
        self.assertIn("previewPlatform !== platform", model)
        self.assertIn("currentFiles[file.handle] == file", model)
        close = model.split("fun close()", 1)[1]
        self.assertLess(close.index("previewReads?.close()"), close.index("owner?.cancelRequests()"))
        # Deliberately leave the product entry pending until EXIF/local/real enqueue are wired too.
        page = source("shared/src/commonMain/kotlin/com/ztransfer/ui/NativeOriginalFilesPage.kt")
        self.assertIn("onPreview = { _, _ -> model.previewPending() }", page)
        self.assertIn("onPreviewBurst = { _, _, _ -> model.previewPending() }", page)
