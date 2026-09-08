"""Current W11-W20 contracts; source checks are not Swift compilation or camera verification."""
import subprocess
from pathlib import Path
import unittest
from transfer_completion_wiring import CHANGES, previous_transfer_completion_source

ROOT = Path(__file__).resolve().parents[2]

class TransferCompletionWiringTest(unittest.TestCase):
    def test_incremental_scan_uses_existing_owner_and_keeps_commit_fence(self):
        source = (ROOT / "iosApp/ZTransfer/Network/CameraCatalog.swift").read_text(encoding="utf8")
        for token in ["Int(scan.rowCount) - publishedRows >= 20", "change == nil, scan.metadataComplete",
                      "current.eventRevision == before.eventRevision", "previews?.appendCatalogBatch(",
                      "if let callback = batch ?? onBatch", "progressSnapshot = nil",
                      "if result.metadataComplete && !result.changedWhileScanning { latest = result }"]:
            self.assertIn(token, source)
        body = source.split("var publishedRows = 0", 1)[1].split("let after = await source.snapshot()", 1)[0]
        self.assertNotIn("latest = ", body)
        self.assertNotIn("publishScanAdditions", body)
        self.assertNotIn("onAddition", body)

    def test_batch_fill_never_prunes_disk_and_failure_restores_committed_page(self):
        source = (ROOT / "iosApp/ZTransfer/Network/CameraPreviewStore.swift").read_text(encoding="utf8")
        body = source.split("func appendCatalogBatch", 1)[1].split("func fillCounts", 1)[0]
        self.assertIn("scanToken == token", body)
        self.assertIn("fill.appendScanBatch", body)
        self.assertNotIn("disk?.reconcile", body)
        self.assertIn("if let previous = lastCompleteSnapshot", source)
        page = (ROOT / "iosApp/ZTransfer/UI/OriginalFilesPage.swift").read_text(encoding="utf8")
        for token in ["model.publishScanBatch", "filesByHandle = committedFiles", "model.currentScanSequence()",
                      "value?.publicationRevision ?? publication", "committedFiles.removeAll()"]:
            self.assertIn(token, page)
        home = (ROOT / "iosApp/ZTransfer/UI/CameraWorkspace.swift").read_text(encoding="utf8")
        self.assertNotIn("pendingFilesNavigation", home)
        self.assertNotIn("session.$scanningCatalog.sink", home)

    def test_camera_thumbnail_orientation_crop_order_and_native_decode_budgets_are_explicit(self):
        source = (ROOT / "iosApp/ZTransfer/Storage/PreviewImageDecoder.swift").read_text(encoding="utf8")
        body = source.split("private func thumbnailPNG", 1)[1].split("private func resizeThumbnail", 1)[0]
        self.assertIn("CGImageSourceCreateImageAtIndex", body)
        self.assertIn("thumbnailPolicy.thumbnailPixelsAllowed", body)
        self.assertLess(body.index("cropThumbnail(decoded"), body.index("resizeThumbnail(cropped"))
        self.assertNotIn("kCGImageSourceCreateThumbnailWithTransform", body)
        self.assertIn("thumbnailPolicy.originalPixelsAllowed", source)
        reader = (ROOT / "iosApp/ZTransfer/Storage/IndexedOriginalReader.swift").read_text(encoding="utf8")
        self.assertIn("maximumFileBytes: 256 * 1024 * 1024", reader)
        self.assertIn("maximumFileBytes: Int64.max, allowEmpty: true", reader)

    def test_exif_oracle_and_apple_media_batch_cases_are_registered(self):
        oracle = (ROOT / "iosApp/scripts/exif_oracle/ExifRationalOracle.java").read_text(encoding="utf8")
        for token in ["new ExifInterface(new ByteArrayInputStream(bytes))", "rawWithEmbeddedJpeg",
                      "checkMetadata", "metadataText", "PreviewExifRationalReader.INSTANCE.readMetadata"]:
            self.assertIn(token, oracle)
        source = (ROOT / "iosApp/ZTransferTests/CameraNetworkTests.swift").read_text(encoding="utf8")
        for name in ["testRawEmbeddedExifUsesSharedDirectoryRouteWithoutMutatingOriginal",
                     "testIncrementalCatalogPublishesBeforeWholeMetadataAndNeverCommitsPartialBaseline",
                     "testIncrementalThumbnailFillRunsBeforeScanFinishWithoutDeletingPreviousDiskEntries",
                     "testDirectVideoThumbnailReusesHeaderJpegAndKeepsVideoIdentity",
                     "testVideoPrefixDecoderRejectsBadOrOversizedInputAndHonorsCancellation",
                     "testEmbeddedExifThumbnailCanDecodeWithoutPrimaryImageEntropy"]:
            self.assertIn("func " + name, source)

    def test_full_file_guard_rejects_any_unreviewed_suffix(self):
        for path in CHANGES:
            actual = (ROOT / path).read_text(encoding="utf8")
            with self.assertRaises(AssertionError):
                previous_transfer_completion_source(path, actual + "\n// unreviewed mutation\n")

    def test_thumbnail_detection_is_exact_android_extraction(self):
        import thumbnail_crop_extraction as crop
        crop.verify()

    def test_sta_previews_use_shared_parsers_and_never_download_primary(self):
        source = (ROOT / "iosApp/ZTransfer/Network/CameraWiFiConnection.swift").read_text(encoding="utf8")
        body = source.split("private func directFhdPicture", 1)[1].split("/// Same interactive owner", 1)[0]
        for token in ["staPreviewPolicy.shouldRequest", ".mpf(", ".rawIndexed(", ".rawThumbnailProbe(",
                      ".scannedJpeg(", "directThumbnailMisses.insert", "revision == directContentRevision",
                      "directDecoder.videoThumbnail", "16 * 1024 * 1024"]:
            self.assertIn(token, body)
        self.assertNotIn("PtpConstants.shared.GET_OBJECT,", body)
        self.assertNotIn("executeStreaming", body)
        decoder = (ROOT / "iosApp/ZTransfer/Storage/PreviewImageDecoder.swift").read_text(encoding="utf8")
        for token in ["NativeThumbnailCropBridge.shared.crop", "source.cropping(", "cancelAllCGImageGeneration()",
                      "prefix.count <= 8 * 1024 * 1024", "defer { try? FileManager.default.removeItem(at: url) }"]:
            self.assertIn(token, decoder)

    def test_entire_android_sta_io_and_original_pure_parsers_are_preserved(self):
        import sta_media_extraction as sta
        sta.verify()

    def test_direct_catalog_download_and_index_paths_are_real_and_bounded(self):
        source = (ROOT / "iosApp/ZTransfer/Network/CameraWiFiConnection.swift").read_text(encoding="utf8")
        for token in ["return try await directObjectInfo(handle: handle", "NativeStaDirectMetadata()",
                      "bridge.headerInfo(model: directMetadata", "directMetadata.indexedInfo(",
                      "bridge.loadDates(model:", "bridge.loadNames(model:",
                      "forcePartial: directObjectReadValidated", "maximumBytes: directObjectReadValidated ? requested",
                      "while directHeaderOrder.count > 4", "revision == directContentRevision"]:
            self.assertIn(token, source)
        catalog = (ROOT / "iosApp/ZTransfer/Network/CameraCatalog.swift").read_text(encoding="utf8")
        self.assertIn("source.prepareDirectCatalog(", catalog)
        self.assertIn("scan.enableDirectObjectReads()", catalog)
        self.assertIn("let filters = scan.filterStorageIds()", catalog)
        self.assertIn("if result.metadataComplete && !result.changedWhileScanning { latest = result }", catalog)

    def test_direct_wire_fixture_opcodes_match_independent_protocol_constants(self):
        source = (ROOT / "iosApp/ZTransferTests/CameraNetworkTests.swift").read_text(encoding="utf8")
        self.assertIn("[0x9421, 0x9431]", source)
        self.assertIn("[0x9431, 0x1009]", source)
        for name in ["testDirectCatalogUsesSharedHeaderNameAndPreservesGoodRowsAfterObjectFailure",
                     "testDirectOriginalForcesSharedPartialPolicyEvenOnHighThroughputPage",
                     "testDirectOriginalUnsupportedFirstEmptyChunkUsesOnlySharedFullFallback",
                     "testDirectResumeReadsOnlyRemainingBytesAndNeverFallsBackAfterUnsupportedResponse",
                     "testDirectOversizedChunkCannotBecomeASuccessfulOriginal"]:
            self.assertIn("func " + name, source)

    def test_reviewed_changes_restore_entire_previous_production_files(self):
        for path in CHANGES:
            actual = (ROOT / path).read_text(encoding="utf8")
            previous = subprocess.check_output(["git", "show", "e5dbadb:" + path], cwd=ROOT).decode()
            self.assertEqual(previous_transfer_completion_source(path, actual), previous, path)

    def test_home_uses_actual_ready_generation_and_original_timing_functions(self):
        import home_card_extraction as home
        home.verify()
        text = (ROOT / "shared/src/commonMain/kotlin/com/ztransfer/ui/NativeConnectionHome.kt").read_text(encoding="utf8")
        for token in ["LaunchedEffect(model, state.requestId, state.ready)", "withFrameNanos",
                      "connectionHeroProgress(elapsed.longValue)", "connectionSuccessProgress(elapsed.longValue)",
                      "celebratedRequest != requestId", "model.celebrationFinished(request)", "model::stopSearching"]:
            self.assertIn(token, text)
        self.assertNotIn("selectionSceneProgress = { 0f }", text)

    def test_pairing_feedback_is_scoped_to_same_opening_owner(self):
        text = (ROOT / "iosApp/ZTransfer/Diagnostics/CameraHandshakeProbe.swift").read_text(encoding="utf8")
        body = text.split("private func publishPairingStarted", 1)[1].split("func start(", 1)[0]
        for token in ["!Task.isCancelled", "apConnection?.connectionID == connectionID",
                      "productState?.requestID == requestID", 'productState?.phase == "connecting"']:
            self.assertIn(token, body)

    def test_station_compatibility_is_explicit_and_sample_reads_are_bounded(self):
        text = (ROOT / "iosApp/ZTransfer/Network/CameraWiFiConnection.swift").read_text(encoding="utf8")
        self.assertIn("&& !options.exploreAlbumAccess", text)
        self.assertIn("if options.exploreAlbumAccess {", text)
        self.assertIn("operationCode: 0x9435, parameters: [0], timeout: 5", text)
        body = text.split("private func validateStationObjectAccess", 1)[1].split("private func pairStation", 1)[0]
        for token in ["[0, (handles.count - 1) / 2, handles.count - 1]", "sampled.insert(index).inserted",
                      "parameters: [handle, 0, 0, 64 * 1024, 0]", "maximumPayloadBytes: 64 * 1024",
                      "PtpIPChannel.objectSize($0) > 0", "prefix.payload?.isEmpty == false"]:
            self.assertIn(token, body)
        self.assertNotIn("PtpConstants.shared.GET_OBJECT,", body)
        self.assertNotIn("executeStreaming", body)

    def test_registered_apple_fixtures_cover_connection_close_and_station_evidence(self):
        text = (ROOT / "iosApp/ZTransferTests/CameraWorkspaceTests.swift").read_text(encoding="utf8")
        self.assertIn("func testClosingWorkspaceCancelsPendingConnectionAndNeverCreatesPages", text)
        text = (ROOT / "iosApp/ZTransferTests/CameraNetworkTests.swift").read_text(encoding="utf8")
        for name in ["testStationCompatibilityValidatesFirstMiddleLastBeforeReadyAndReusesSingleCardHandles",
                     "testStationDirectCapabilityRequiresBothSizeAndSuccessfulNonemptyPartialSample",
                     "testFailedStationApplicationModeProbeRollsBackAndNeverBecomesReady"]:
            self.assertIn("func " + name, text)

if __name__ == "__main__":
    unittest.main()
