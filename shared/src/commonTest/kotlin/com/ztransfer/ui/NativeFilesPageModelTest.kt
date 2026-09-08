package com.ztransfer.ui

import com.ztransfer.catalog.UNKNOWN_CAPTURE_DATE_GROUP_KEY
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.NativeOriginalIndexUpdate
import com.ztransfer.ui.screen.SharedPhotoFilterCriteria
import kotlin.coroutines.*
import kotlin.test.*

class NativeFilesPageModelTest {
    @Test fun memoryPressureDoesNotChangeCatalogQueueOrPreferencesAndCannotReviveClosedPage() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        val before = m.state.value
        val preferences = m.filters.value
        m.releaseImageMemory()
        assertEquals(1L, m.memoryRevision.value)
        assertSame(before, m.state.value); assertEquals(preferences, m.filters.value)
        m.close(); m.releaseImageMemory()
        assertEquals(1L, m.memoryRevision.value)
    }
    @Test fun automaticArrivalRequiresBothCatalogIntentAndOneActualQueuePublication() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        fun queued(sequence: Long, id: Long) = NativeQueuePageSnapshot("camera", sequence, sequence, false, false).also {
            it.addOriginal(id, file.handle, file.size, file.fileName, file.captureDate, file.isProtected,
                file.storageIds.toIntArray(), null, "WAITING", 0, 0f, 0, null, null, 0f)
        }
        m.queue.publish(queued(1, 1)); m.observeQueuePublication()
        assertEquals(0, m.arrivals.value.revision) // Initial history never receives an animation.
        m.expectAutomaticArrival(file)
        m.queue.publish(queued(2, 2)); m.observeQueuePublication()
        assertEquals(listOf(file), m.arrivals.value.files)
        assertEquals(1, m.arrivals.value.revision)
        m.observeQueuePublication(); assertEquals(1, m.arrivals.value.revision)
        m.close(); m.expectAutomaticArrival(file); m.observeQueuePublication()
        assertEquals(NativeQueueArrival(), m.arrivals.value)
    }

    @Test fun exportUsesTheIndexedCopyNameAndRealSizeInsteadOfTheCameraSentinel() {
        val m = model()
        val camera = CameraFileInfo(1, com.ztransfer.protocol.PtpConstants.SIZE_UNKNOWN, "DSC_0001.JPG", null)
        assertTrue(m.publishOriginals(NativeOriginalIndexUpdate(1, -1, true).also {
            it.add("dsc_0001 (2).jpg", 5_000_000_000L, null, "frozen-copy")
        }))
        val item = m.originalActionItems(listOf(camera)).single()
        assertEquals(camera, item.file)
        assertEquals("dsc_0001 (2).jpg", item.originalName)
        assertEquals(5_000_000_000L, item.originalSize)
        assertEquals("frozen-copy", item.locator)
    }
    @Test fun dateAndBurstBatchesUseCurrentFilteredSlotAndOriginalGridOrdering() {
        val p = Platform(); val m = model(p)
        val input = snapshot().also {
            it.addFile(4, 100, "OTHER.NEF", "20260905T120004", true, intArrayOf(0x20001))
        }
        assertTrue(m.finishScan(m.beginScan(), input))
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria(storageSlot = 1, protectedOnly = true)))
        val current = m.state.value
        val chosen = nativeFilteredCameraFiles(current.files, current.storageIds, m.filters.value,
            current.bursts.flatMap { it.files }.map { it.handle }.toSet(), emptySet())
        assertEquals(listOf(1), chosen.map { it.handle })
        val admitted = start { m.enqueue(chosen) }
        assertContentEquals(intArrayOf(1), p.requested)
        p.enqueueResult!!.complete(1)
        assertEquals(1, admitted.result!!.getOrThrow())
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria()))
        val all = m.state.value.groups.single().files
        val batch = start { m.enqueue(all) }
        assertContentEquals(all.map { it.handle }.toIntArray(), p.requested)
        p.enqueueResult!!.complete(all.size)
        assertEquals(all.size, batch.result!!.getOrThrow())
    }

    @Test fun aFrozenBatchIsRejectedIfAHandleIsReusedBeforeAdmission() {
        val p = Platform(); val m = model(p)
        m.finishScan(m.beginScan(), snapshot())
        val chosen = m.state.value.files
        val replacement = NativeFilesPageSnapshot("camera", true, false).also {
            it.addFile(1, 987, "DIFFERENT.JPG", "20260905T130000", false, intArrayOf(0x10001))
        }
        m.finishScan(m.beginScan(), replacement)
        assertEquals(0, start { m.enqueue(chosen) }.result!!.getOrThrow())
        assertNull(p.enqueueResult)
        assertEquals(NativeFilesNotice.ENQUEUE_FAILED, m.state.value.notice)
    }

    @Test fun browseSessionRestoresOnlyTheSameConnectionWithoutPersistingSlots() {
        val p = Platform(); val m = model(p)
        m.finishScan(m.beginScan(), snapshot())
        m.changeFilters(SharedPhotoFilterCriteria(storageSlot = 2, protectedOnly = true))
        m.browseSession.firstVisibleIndex = 19
        m.browseSession.firstVisibleOffset = 37
        m.browseSession.collapsedDates["20260905"] = true
        val memory = m.captureBrowseSession()
        m.close()
        val restored = model(p)
        assertTrue(restored.restoreBrowseSession(memory))
        assertEquals(2, restored.filters.value.storageSlot)
        assertEquals(19, restored.browseSession.firstVisibleIndex)
        assertEquals(37, restored.browseSession.firstVisibleOffset)
        assertEquals(true, restored.browseSession.collapsedDates["20260905"])
        assertNull(p.preferences!!.criteria().storageSlot)
        assertFalse(restored.restoreBrowseSession(NativeBrowseSession("other")))
        assertTrue(restored.finishScan(restored.beginScan(), snapshot()))
        assertFalse(restored.restoreBrowseSession(memory))
        assertNull(model(p).filters.value.storageSlot)
    }

    @Test fun incrementalRowsAreVisibleButFailureRestoresTheCompleteCatalog() {
        val m = model()
        assertTrue(m.finishScan(m.beginScan(), snapshot()))
        val original = m.state.value
        val sequence = m.beginScan()
        val batch = NativeFilesPageSnapshot("camera", false, false).also {
            it.addFile(9, 10, "NEW.JPG", "20260906T120000", false, intArrayOf(0x10001))
        }
        assertTrue(m.publishScanBatch(sequence, batch))
        assertTrue(m.state.value.scanning)
        assertEquals(setOf(1, 2, 3, 9), m.state.value.files.map { it.handle }.toSet())
        assertEquals(original.scanSequence, m.state.value.scanSequence)
        assertFalse(m.finishScan(sequence, null))
        assertEquals(original.files, m.state.value.files)
        assertEquals(NativeFilesNotice.SCAN_FAILED, m.state.value.notice)
        assertEquals(0, m.currentScanSequence())
    }

    @Test fun lateForeignAndRacedBatchesCannotChangeRowsOrNormalizeFilters() {
        val m = model()
        val sequence = m.beginScan()
        assertFalse(m.publishScanBatch(sequence + 1, snapshot()))
        assertFalse(m.publishScanBatch(sequence, snapshot(connection = "other")))
        assertFalse(m.publishScanBatch(sequence, snapshot(changed = true)))
        assertTrue(m.state.value.files.isEmpty())
        assertTrue(m.publishScanBatch(sequence, snapshot(complete = false)))
        assertFalse(m.state.value.hasSnapshot)
        assertTrue(m.finishScan(sequence, snapshot()))
        assertFalse(m.publishScanBatch(sequence, snapshot()))
        m.close()
        assertEquals(0, m.currentScanSequence())
    }

    @Test fun explicitTransferPreferenceReloadDoesNotRecreateCatalogOrBrowseState() {
        val p = Platform(); val m = model(p)
        m.finishScan(m.beginScan(), snapshot()); m.setOrganizeByDate(true); m.setDeferStart(true)
        val catalog = m.state.value; val browse = m.layout.value
        p.transfers = NativeTransferPreferences.defaults()
        m.reloadTransferPreferences()
        assertEquals(NativeTransferPreferences.defaults(), m.currentTransferPreferences())
        assertEquals(catalog, m.state.value); assertEquals(browse, m.layout.value)
        m.close(); p.transfers = NativeTransferPreferences(true, true); m.reloadTransferPreferences()
        assertEquals(NativeTransferPreferences.defaults(), m.currentTransferPreferences())
    }

    @Test fun transferPreferencesRestoreAndPersistIndependentlyOfBrowseAndCatalog() {
        val p = Platform(); val m = model(p)
        m.finishScan(m.beginScan(), snapshot())
        val catalog = m.state.value; val browse = p.preferences
        assertEquals(NativeTransferPreferences.defaults(), m.currentTransferPreferences())
        m.setOrganizeByDate(true); m.setDeferStart(true)
        assertEquals(NativeTransferPreferences(true, true), p.transfers)
        assertEquals(2, p.transferWrites)
        assertEquals(catalog, m.state.value); assertSame(browse, p.preferences)
        m.changeLayout(4, false)
        assertEquals(NativeTransferPreferences(true, true), model(p).currentTransferPreferences())
        m.setOrganizeByDate(true); m.setDeferStart(true)
        assertEquals(2, p.transferWrites)
        m.close(); m.setOrganizeByDate(false); m.setDeferStart(false)
        assertEquals(2, p.transferWrites)
    }

    @Test fun transferPreferenceFailureDoesNotDiscardLiveSelectionOrGetClearedByBrowseSave() {
        val p = Platform().also { it.transfers = null; it.transferSaveSucceeds = false }
        val m = model(p)
        assertTrue(m.transferPreferencesFailed.value)
        assertEquals(NativeTransferPreferences.defaults(), m.currentTransferPreferences())
        m.setOrganizeByDate(true)
        assertTrue(m.currentTransferPreferences().organizeByDate)
        assertTrue(m.transferPreferencesFailed.value)
        m.changeLayout(4, false)
        assertFalse(m.preferencesFailed.value)
        assertTrue(m.transferPreferencesFailed.value)
        assertNull(p.transfers)
    }

    @Test fun savedBadgeFilterAndPreviewAllUseTheSameSelectedDateBucket() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        assertTrue(m.publishOriginals(NativeOriginalIndexUpdate(1, -1, true).also {
            it.add(file.fileName, file.size, null, "root")
            it.add(file.fileName, file.size, "ZT2026-09-05", "dated")
        }))
        assertEquals("root", m.localOriginalSource(file))
        m.setOrganizeByDate(true)
        assertEquals("dated", m.localOriginalSource(file)); assertTrue(m.isTransferred(file))
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria(untransferredOnly = true)))
        assertEquals(setOf(file.handle), m.transferredHandlesForFilter())
        assertTrue(m.publishOriginals(NativeOriginalIndexUpdate(2, -1, true).also {
            it.add(file.fileName, file.size, null, "root-only")
        }))
        assertFalse(m.isTransferred(file)); assertNull(m.localOriginalSource(file))
        assertTrue(m.transferredHandlesForFilter().isEmpty())
        m.setOrganizeByDate(false)
        assertEquals("root-only", m.localOriginalSource(file)); assertTrue(m.isTransferred(file))
    }

    @Test fun missingCaptureDateFollowsLiveLocalDayButAnAdmittedTaskKeepsItsOldBucket() {
        val p = Platform(); val m = model(p); m.setOrganizeByDate(true)
        val file = CameraFileInfo(7, 3, "UNKNOWN.JPG", null)
        assertTrue(m.publishOriginals(NativeOriginalIndexUpdate(1, -1, true).also {
            it.add(file.fileName, file.size, "ZT2026-09-05", "first")
            it.add(file.fileName, file.size, "ZT2026-09-06", "second")
        }))
        assertEquals("first", m.localOriginalSource(file))
        val info = com.ztransfer.protocol.PtpObjectInfo(7, 1, 0x3801, 3, "UNKNOWN.JPG", null, false, false, true)
        val queue = com.ztransfer.viewmodel.NativeOriginalTransferQueue()
        val admitted = assertNotNull(queue.enqueue(info, m.currentTransferPreferences().organizeByDate, p.dayKey))
        p.dayKey = 20260906
        assertEquals("second", m.localOriginalSource(file))
        assertEquals("ZT2026-09-05", admitted.destinationFolderName)
        m.setOrganizeByDate(false)
        assertNull(m.localOriginalSource(file)); assertEquals("ZT2026-09-05", queue.taskAt(0)?.destinationFolderName)
    }

    @Test fun photoInteractionSurvivesLayoutFilterAndPreviewWritesAndReopensWithoutChangingCatalog() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val catalog = m.state.value
        assertFalse(m.layout.value.tapToPreview)
        m.setTapToPreview(true); m.changeLayout(4, false)
        m.changeFilters(m.filters.value.copy(protectedOnly = true))
        m.setPreviewRotationQuarterTurns(2); m.setPreviewHistogramEnabled(true)
        assertEquals(catalog, m.state.value); assertTrue(m.layout.value.tapToPreview)
        val reopened = model(p)
        assertEquals(NativeBrowseLayout(4, false, true), reopened.layout.value)
        assertTrue(reopened.filters.value.protectedOnly)
        assertEquals(NativePreviewOptions(2, true), reopened.previewOptions.value)
        val writes = p.writes
        m.setTapToPreview(true); assertEquals(writes, p.writes)
        m.setTapToPreview(false); assertFalse(p.preferences!!.tapToPreview)
        assertEquals(4, p.preferences!!.columns); assertFalse(p.preferences!!.collapseBursts)
        m.close(); m.setTapToPreview(true); assertFalse(p.preferences!!.tapToPreview)
        reopened.close()
    }

    @Test fun failedInteractionSaveIsVisibleWithoutEndingActiveReadsAndCanBeRetriedByChangingValue() {
        val p = Platform().also { it.saveSucceeds = false }; val m = model(p)
        var ended = 0
        m.attachPreviewReads(object : NativePreviewReadPlatform {
            override fun beginPreviewReads(sessionId: Long) {}
            override fun endPreviewReads(sessionId: Long) { ended++ }
            override fun cancelPreviewRead(sessionId: Long, requestId: Long) {}
            override fun readFhdPreview(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativeFhdPreviewCompletion) {}
        })
        assertNotNull(m.beginPreviewReads())
        m.setTapToPreview(true)
        assertTrue(m.layout.value.tapToPreview); assertTrue(m.preferencesFailed.value)
        assertFalse(p.preferences!!.tapToPreview); assertEquals(0, ended)
        p.saveSucceeds = true; m.setTapToPreview(false)
        assertFalse(m.preferencesFailed.value); assertEquals(0, ended)
        m.close(); assertEquals(1, ended)
    }

    @Test fun previewMetadataUsesSharedValidationPlatformFieldsAndClosesWithoutMoreWork() {
        val p = Platform(); val m = model(p)
        val file = CameraFileInfo(1, 4294967295L, "VIDEO.MOV", "00000229T000001")
        assertEquals("large  ·  0000-02-29 00:00:01", m.previewMetadata(file, "large"))
        assertEquals("2026-09-05", m.previewMetadata(file.copy(size = 0, captureDate = "20260905T240000"), "large"))
        assertEquals("", m.previewMetadata(file.copy(size = 0, captureDate = "20260229"), "large"))
        assertEquals(0, p.writes); assertNull(p.enqueueResult); assertNull(p.imageResult)
        m.close(); assertEquals("", m.previewMetadata(file, "large"))
    }

    @Test fun previewOptionsRestoreAndSaveTogetherWithFiltersWithoutResettingEachOther() {
        val p = Platform().also { it.preferences = NativeBrowsePreferences(4, false, listOf(".jpg"), true, false, false, 20260101, 20261231, -1, true) }
        val m = model(p)
        assertEquals(NativePreviewOptions(3, true), m.previewOptions.value)
        assertEquals(0, p.writes)
        m.setPreviewRotationQuarterTurns(5)
        assertEquals(NativePreviewOptions(1, true), m.previewOptions.value)
        assertEquals(4, p.preferences!!.columns); assertEquals(listOf(".jpg"), p.preferences!!.extensions)
        assertTrue(p.preferences!!.protectedOnly); assertEquals(20260101, p.preferences!!.startDay)
        m.changeLayout(2, true); m.changeFilters(m.filters.value.copy(burstOnly = true))
        assertEquals(1, p.preferences!!.previewRotationQuarterTurns); assertTrue(p.preferences!!.previewHistogramEnabled)
        m.setPreviewHistogramEnabled(false)
        assertEquals(2, p.preferences!!.columns); assertTrue(p.preferences!!.collapseBursts); assertTrue(p.preferences!!.burstOnly)
        val reopened = model(p)
        assertEquals(NativePreviewOptions(1, false), reopened.previewOptions.value)
        assertEquals(4, p.writes)
        m.setPreviewRotationQuarterTurns(1); m.setPreviewHistogramEnabled(false)
        assertEquals(4, p.writes)
        m.close(); reopened.close()
    }

    @Test fun previewPreferenceFailuresRemainVisibleAndDoNotCancelExistingPreviewReads() {
        val p = Platform().also { it.preferences = null; it.saveSucceeds = false }
        val m = model(p); var ended = 0
        val preview = object : NativePreviewReadPlatform {
            override fun beginPreviewReads(sessionId: Long) {}
            override fun endPreviewReads(sessionId: Long) { ended++ }
            override fun cancelPreviewRead(sessionId: Long, requestId: Long) {}
            override fun readFhdPreview(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativeFhdPreviewCompletion) {}
        }
        assertEquals(NativePreviewOptions(), m.previewOptions.value); assertTrue(m.preferencesFailed.value)
        m.attachPreviewReads(preview); assertNotNull(m.beginPreviewReads())
        m.setPreviewRotationQuarterTurns(-2); m.setPreviewHistogramEnabled(true)
        assertEquals(NativePreviewOptions(2, true), m.previewOptions.value)
        assertTrue(m.preferencesFailed.value); assertNull(p.preferences)
        assertEquals(0, ended); assertTrue(m.queue.connected.value)
        p.saveSucceeds = true; m.setPreviewRotationQuarterTurns(-1)
        assertFalse(m.preferencesFailed.value); assertTrue(p.preferences!!.previewHistogramEnabled)
        assertEquals(3, p.preferences!!.previewRotationQuarterTurns)
        val writes = p.writes
        m.close(); m.setPreviewHistogramEnabled(false); m.setPreviewRotationQuarterTurns(0)
        assertEquals(writes, p.writes); assertEquals(1, ended)
        assertEquals(3, p.preferences!!.previewRotationQuarterTurns); assertTrue(p.preferences!!.previewHistogramEnabled)
    }
    @Test fun previewAdmissionUsesRealFilesModelResultAndKeepsPartialNoticeWithoutFullGroupFlight() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)
        val gate = com.ztransfer.ui.screen.PreviewQueueAcceptance()
        var flights = 0
        assertTrue(gate.request(scope, m.state.value.files, { true }, m::enqueue) { flights++ })
        assertTrue(m.state.value.enqueueing); assertEquals(0, flights)
        p.enqueueResult!!.complete(2)
        assertEquals(NativeFilesNotice.PARTIAL_ENQUEUE, m.state.value.notice)
        assertFalse(m.state.value.enqueueing); assertEquals(0, flights)
        assertTrue(gate.request(scope, m.state.value.files, { true }, m::enqueue) { flights++ })
        p.enqueueResult!!.complete(3)
        assertEquals(1, flights); assertEquals(NativeFilesNotice.NONE, m.state.value.notice)
        gate.close(); m.close()
    }

    @Test fun closingOnlyPreviewCancelsItsWaiterButNeverStopsParentQueueOrAcceptsLateFlight() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)
        val gate = com.ztransfer.ui.screen.PreviewQueueAcceptance()
        var flights = 0
        gate.request(scope, m.state.value.files, { true }, m::enqueue) { flights++ }
        val late = p.enqueueResult!!
        gate.close(); late.complete(3)
        assertEquals(0, flights); assertFalse(m.state.value.enqueueing)
        assertEquals(0, p.cancelled); assertTrue(m.queue.connected.value)
        m.close()
    }

    @Test fun previewSessionsHaveDistinctLifetimesWithoutClosingTheirParentQueue() {
        val events = mutableListOf<String>()
        val preview = object : NativePreviewReadPlatform {
            override fun beginPreviewReads(sessionId: Long) { events += "begin:$sessionId" }
            override fun endPreviewReads(sessionId: Long) { events += "end:$sessionId" }
            override fun cancelPreviewRead(sessionId: Long, requestId: Long) { }
            override fun readFhdPreview(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativeFhdPreviewCompletion) { }
        }
        val m = model()
        assertNull(m.beginPreviewReads()); assertTrue(m.attachPreviewReads(preview))
        val first = assertNotNull(m.beginPreviewReads())
        val second = assertNotNull(m.beginPreviewReads())
        first.close(); second.close()
        assertTrue(m.queue.connected.value)
        assertEquals(listOf("begin:1", "end:1", "begin:2", "end:2"), events)
        m.close(); assertNull(m.beginPreviewReads()); assertFalse(m.attachPreviewReads(preview))
    }

    @Test fun previewOriginalLocatorUsesTheSameRealIndexAsTransferredBadge() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        assertNull(m.localOriginalSource(file))
        val update = NativeOriginalIndexUpdate(1, -1, true)
        update.add(file.fileName, file.size, null, "file:///owned/original.jpg")
        assertTrue(m.publishOriginals(update)); assertTrue(m.isTransferred(file))
        assertEquals("file:///owned/original.jpg", m.localOriginalSource(file))
        m.close(); assertNull(m.localOriginalSource(file))
    }

    @Test fun restoredPendingFilterSurvivesInitialIndexFailureAndCanBeClearedBeforeReadiness() {
        val p = Platform().also { it.preferences = NativeBrowsePreferences(4, false, listOf(".jpg"), true, false, true, 20260101, 20261231) }
        val m = model(p)
        assertEquals(NativeBrowseLayout(4, false), m.layout.value)
        assertTrue(m.filters.value.untransferredOnly); assertFalse(m.originals.value.ready)
        m.originalsRefreshFailed()
        assertTrue(m.filters.value.untransferredOnly)
        assertTrue(m.changeFilters(m.filters.value.copy(protectedOnly = false)))
        assertTrue(p.preferences!!.untransferredOnly)
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria()))
        assertFalse(p.preferences!!.untransferredOnly)
        assertNull(p.preferences!!.extensions)
        assertEquals(0, p.preferences!!.startDay)
        assertFalse(m.changeFilters(SharedPhotoFilterCriteria(untransferredOnly = true)))
    }

    @Test fun layoutAndFiltersPersistTogetherButStorageSlotNeverLeaksAcrossRestore() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        m.changeLayout(4, false)
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria(storageSlot = 2, burstOnly = true)))
        assertEquals(2, m.filters.value.storageSlot)
        val reopened = model(p)
        assertEquals(NativeBrowseLayout(4, false), reopened.layout.value)
        assertTrue(reopened.filters.value.burstOnly); assertNull(reopened.filters.value.storageSlot)
        assertEquals(2, p.writes)
        assertFalse(m.changeFilters(m.filters.value)); m.changeLayout(4, false)
        assertEquals(2, p.writes)
    }

    @Test fun preferenceFailureKeepsCurrentSessionUsableAndDoesNotResetCameraOrDiskIndex() {
        val p = Platform().also { it.preferences = null; it.saveSucceeds = false }
        val m = model(p)
        assertTrue(m.preferencesFailed.value)
        assertEquals(NativeBrowseLayout(), m.layout.value)
        m.finishScan(m.beginScan(), snapshot())
        val first = m.state.value.files.first()
        m.publishOriginals(NativeOriginalIndexUpdate(1, -1, true).also { it.add(first.fileName, first.size, null, "real") })
        m.changeLayout(2, false)
        assertEquals(2, m.layout.value.columns); assertTrue(m.preferencesFailed.value)
        assertTrue(m.isTransferred(first)); assertEquals(3, m.state.value.files.size)
        assertNull(p.preferences)
        p.saveSucceeds = true
        m.changeLayout(3, false)
        assertFalse(m.preferencesFailed.value)
    }

    @Test fun closingDoesNotPersistResetValuesOrAllowLatePreferenceWrites() {
        val p = Platform(); val m = model(p)
        m.changeLayout(4, false)
        m.changeFilters(SharedPhotoFilterCriteria(protectedOnly = true))
        val writes = p.writes
        m.close()
        m.changeLayout(2, true); m.changeFilters(SharedPhotoFilterCriteria())
        assertEquals(writes, p.writes)
        assertEquals(4, p.preferences!!.columns); assertTrue(p.preferences!!.protectedOnly)
    }

    @Test fun filtersUseLiveAtomicValuesAndCopyCallerSets() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        val extensions = mutableSetOf(".jpg")
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria(extensions = extensions, protectedOnly = true)))
        extensions.clear()
        assertEquals(setOf(".jpg"), m.filters.value.extensions)
        assertTrue(m.changeFilters(m.filters.value.copy(protectedOnly = false)))
        assertFalse(m.filters.value.protectedOnly)
        assertFalse(m.changeFilters(m.filters.value))
    }

    @Test fun onlyCompleteStorageMetadataCanClearAnUnavailableSlot() {
        val m = model(); val input = snapshot()
        val stores = intArrayOf(0x10001, 0x20001)
        input.setStorageIds(stores); stores[1] = 0
        assertTrue(m.finishScan(m.beginScan(), input))
        input.setStorageIds(intArrayOf())
        assertEquals(listOf(0x10001, 0x20001), m.state.value.storageIds)
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria(storageSlot = 2)))
        val partial = snapshot(complete = false).also { it.setStorageIds(intArrayOf(0x10001)) }
        assertFalse(m.finishScan(m.beginScan(), partial)); assertEquals(2, m.filters.value.storageSlot)
        val complete = snapshot().also { it.setStorageIds(intArrayOf(0x10001)) }
        assertTrue(m.finishScan(m.beginScan(), complete)); assertNull(m.filters.value.storageSlot)
    }

    @Test fun untransferredRequiresAnActualIndexAndSharesTheSavedBadgePredicate() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        assertFalse(m.changeFilters(SharedPhotoFilterCriteria(untransferredOnly = true)))
        assertFalse(m.filters.value.untransferredOnly)
        val first = m.state.value.files.first()
        assertTrue(m.publishOriginals(NativeOriginalIndexUpdate(1, -1, true).also {
            it.add(first.fileName, first.size, null, "real-original")
        }))
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria(untransferredOnly = true)))
        assertEquals(setOf(first.handle), m.transferredHandlesForFilter())
        assertTrue(m.isTransferred(first))
        m.originalsRefreshFailed()
        assertEquals(setOf(first.handle), m.transferredHandlesForFilter())
        assertTrue(m.changeFilters(SharedPhotoFilterCriteria()))
        assertTrue(m.transferredHandlesForFilter().isEmpty())
        assertTrue(m.isTransferred(first)) // Clearing filters never clears the actual file index.
    }

    @Test fun closingDateEditorHostReleasesPlatformButRetainsItsLastRealDayForDismissalFrames() {
        val p = Platform(); val m = model(p)
        p.dayKey = 20260906
        assertEquals(20260906, m.currentDayKey())
        m.close(); p.dayKey = 20260907
        assertEquals(20260906, m.currentDayKey())
        assertFalse(m.changeFilters(SharedPhotoFilterCriteria(protectedOnly = true)))
    }

    @Test fun actualSavedIndexSurvivesScanFailureAndIsIndependentOfQueueHistory() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        assertFalse(m.isTransferred(file))
        m.beginOriginalsRefresh()
        val index = NativeOriginalIndexUpdate(1, -1, true).also {
            it.add(file.fileName, file.size, null, "actual-original")
        }
        assertTrue(m.publishOriginals(index))
        assertTrue(m.originals.value.ready); assertTrue(m.isTransferred(file))
        assertTrue(m.queue.state.value.tasks.isEmpty())
        m.beginOriginalsRefresh(); m.originalsRefreshFailed()
        assertTrue(m.originals.value.failed); assertFalse(m.originals.value.refreshing)
        assertTrue(m.isTransferred(file)); assertEquals(1L, m.originals.value.revision)
        assertFalse(m.publishOriginals(NativeOriginalIndexUpdate(2, 0, false)))
        assertTrue(m.isTransferred(file))
        m.close()
        assertFalse(m.publishOriginals(index)); assertFalse(m.isTransferred(file))
        assertFalse(m.originals.value.ready)
    }

    @Test fun savedDateBucketDoesNotMarkRootDefaultAsTransferred() {
        val m = model(); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        val index = NativeOriginalIndexUpdate(1, -1, true).also {
            it.add(file.fileName, file.size, "ZT2026-09-05", "dated-original")
        }
        assertTrue(m.publishOriginals(index)); assertFalse(m.isTransferred(file))
    }

    private class Platform : NativeFilesPagePlatform, NativeQueuePagePlatform {
        var transfers: NativeTransferPreferences? = NativeTransferPreferences.defaults()
        var transferWrites = 0
        var transferSaveSucceeds = true
        override fun readTransferPreferences() = transfers
        override fun saveTransferPreferences(value: NativeTransferPreferences): Boolean {
            transferWrites++
            if (transferSaveSucceeds) transfers = value
            return transferSaveSucceeds
        }
        override fun previewDateText(year: Int, month: Int, day: Int) = "${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}-${day.toString().padStart(2, '0')}"
        override fun previewTimeText(hour: Int, minute: Int, second: Int) = "${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}:${second.toString().padStart(2, '0')}"
        var preferences: NativeBrowsePreferences? = NativeBrowsePreferences.defaults()
        var saveSucceeds = true
        var writes = 0
        override fun readBrowsePreferences() = preferences
        override fun saveBrowsePreferences(value: NativeBrowsePreferences): Boolean {
            writes++
            if (saveSucceeds) preferences = value
            return saveSucceeds
        }
        var dayKey = 20260905
        override fun currentDayKey() = dayKey
        var cancelled = 0
        var connectionHelp = 0
        var requested = intArrayOf()
        var sequence = 0L
        var enqueueResult: NativeFilesEnqueueCompletion? = null
        var imageResult: NativeFilesThumbnailCompletion? = null
        override fun refresh() {}
        override fun enqueue(handles: IntArray, scanSequence: Long, completion: NativeFilesEnqueueCompletion) {
            requested = handles; sequence = scanSequence; enqueueResult = completion
        }
        var thumbnailRemote: Boolean? = null
        override fun thumbnail(file: CameraFileInfo, allowRemote: Boolean, completion: NativeFilesThumbnailCompletion) {
            thumbnailRemote = allowRemote; imageResult = completion
        }
        override fun cancelRequests() { cancelled++ }
        override fun showConnectionHelp() { connectionHelp++ }
        override fun completedSpeed(value: Float) = ""
        override fun fixed(value: Double, fractionDigits: Int) = ""
        override fun execute(command: NativeQueueCommand, taskId: Long, excludedTaskIds: LongArray, completion: NativeQueueActionCompletion) {}
        override fun thumbnail(file: CameraFileInfo, completion: NativeQueueThumbnailCompletion) {}
    }
    private fun model(platform: Platform = Platform()): NativeFilesPageModel =
        NativeFilesPageModel("camera", NativeQueuePageModel("camera", platform).also { it.setConnected(true) }, platform)
    private fun snapshot(connection: String = "camera", complete: Boolean = true, changed: Boolean = false) =
        NativeFilesPageSnapshot(connection, complete, changed).also { s ->
            s.setStorageIds(intArrayOf(0x10001, 0x20001))
            (1..3).forEach { assertTrue(s.addFile(it, 1024, "DSC_${it.toString().padStart(4, '0')}.JPG",
                "20260905T12000$it", it == 1, intArrayOf(0x10001, 0x20001))) }
        }
    private class Outcome<T> { var result: Result<T>? = null }
    private fun <T> start(block: suspend () -> T) = Outcome<T>().also { outcome ->
        block.startCoroutine(object : Continuation<T> {
            override val context = EmptyCoroutineContext
            override fun resumeWith(result: Result<T>) { outcome.result = result }
        })
    }

    @Test fun snapshotUsesSharedDateAndBurstRulesAndIsIsolatedFromBuilderMutation() {
        val m = model(); val input = snapshot()
        input.addFile(7, 0, "UNKNOWN.JPG", null, false, intArrayOf(1))
        assertTrue(m.finishScan(m.beginScan(), input))
        assertEquals(UNKNOWN_CAPTURE_DATE_GROUP_KEY, m.state.value.groups.first().date)
        assertEquals(listOf(3, 2, 1), m.state.value.groups.last().files.map { it.handle })
        assertEquals(3, m.state.value.bursts.single().files.size)
        assertEquals(setOf(0x10001, 0x20001), m.state.value.files.first().storageIds)
        input.addFile(9, 10, "LATE.JPG", null, false, intArrayOf())
        assertEquals(4, m.state.value.files.size)
    }

    @Test fun failedPartialRacedAndWrongCameraResultsCannotClearPublishedList() {
        val m = model(); assertTrue(m.finishScan(m.beginScan(), snapshot()))
        val old = m.state.value.files
        for (input in listOf(null, snapshot(complete = false), snapshot(changed = true), snapshot(connection = "old"))) {
            assertFalse(m.finishScan(m.beginScan(), input))
            assertSame(old, m.state.value.files)
            assertFalse(m.state.value.scanning)
        }
    }

    @Test fun scanTokensDuplicatesAndDisconnectAreRejectedAtomically() {
        val m = model(); val first = m.beginScan()
        assertEquals(0L, m.beginScan())
        assertTrue(m.finishScan(first, snapshot()))
        val second = m.beginScan()
        assertFalse(m.finishScan(first, snapshot()))
        assertTrue(m.state.value.scanning)
        val duplicate = snapshot(); assertFalse(duplicate.addFile(1, 0, "X", null, false, intArrayOf()))
        assertFalse(m.finishScan(second, duplicate))
        val third = m.beginScan(); m.queue.setConnected(false)
        assertFalse(m.finishScan(third, snapshot()))
        assertEquals(0L, m.beginScan())
        assertEquals(3, m.state.value.files.size)
    }

    @Test fun enqueuePreservesVisibleOrderAndWaitsForActualResult() {
        val p = Platform(); val m = model(p); val seq = m.beginScan()
        assertTrue(m.finishScan(seq, snapshot()))
        val operation = start { m.enqueue(m.state.value.groups.single().files) }
        assertNull(operation.result); assertTrue(m.state.value.enqueueing)
        assertContentEquals(intArrayOf(3, 2, 1), p.requested); assertEquals(seq, p.sequence)
        assertEquals(0L, m.beginScan())
        p.enqueueResult!!.complete(2)
        assertEquals(2, operation.result!!.getOrThrow())
        assertFalse(m.state.value.enqueueing)
        assertEquals(NativeFilesNotice.PARTIAL_ENQUEUE, m.state.value.notice)
        p.enqueueResult!!.complete(3) // Late duplicate acknowledgement is ignored.
        assertEquals(NativeFilesNotice.PARTIAL_ENQUEUE, m.state.value.notice)
    }

    @Test fun staleRowsAndDuplicateSelectionsDoNotCrossPlatformBoundary() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        assertEquals(0, start { m.enqueue(listOf(file.copy(size = 99))) }.result!!.getOrThrow())
        assertEquals(0, start { m.enqueue(listOf(file, file)) }.result!!.getOrThrow())
        assertNull(p.enqueueResult)
        val good = start { m.enqueue(listOf(file)) }; p.enqueueResult!!.complete(100)
        assertEquals(0, good.result!!.getOrThrow())
        assertEquals(NativeFilesNotice.ENQUEUE_FAILED, m.state.value.notice)
        m.queue.setConnected(false)
        assertEquals(0, start { m.enqueue(listOf(file)) }.result!!.getOrThrow())
        assertEquals(1, p.connectionHelp)
    }

    @Test fun closeCancelsPendingWorkAndNeverReopensThePageOnLateCallbacks() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        val enqueue = start { m.enqueue(listOf(file)) }
        val image = start { m.thumbnail(file) }
        m.close(); m.close()
        assertTrue(enqueue.result!!.isFailure); assertTrue(image.result!!.isFailure)
        p.enqueueResult!!.complete(1); p.imageResult!!.complete(byteArrayOf(1), false)
        assertTrue(m.state.value.files.isEmpty()); assertFalse(m.queue.connected.value)
        assertEquals(0L, m.beginScan())
        assertEquals(2, p.cancelled) // Same test object represents the two separate platform adapters.
    }

    @Test fun thumbnailPayloadLimitAndTransientRetryResultAreExplicit() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        val pending = start { m.thumbnail(file) }; p.imageResult!!.complete(null, true)
        assertTrue(pending.result!!.getOrThrow().retryable)
        val oversized = start { m.thumbnail(file) }; p.imageResult!!.complete(ByteArray(4 * 1024 * 1024 + 1), false)
        assertNull(oversized.result!!.getOrThrow().bytes)
    }

    @Test fun localThumbnailRequestCanReadDiskOfflineAndDoesNotEscalateToRemote() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first(); m.queue.setConnected(false)
        val rejected = start { m.thumbnail(file) }
        assertNull(rejected.result!!.getOrThrow().bytes); assertNull(p.thumbnailRemote)
        val local = start { m.thumbnail(file, allowRemote = false) }
        assertEquals(false, p.thumbnailRemote); assertNull(local.result)
        p.imageResult!!.complete(byteArrayOf(1), false)
        assertContentEquals(byteArrayOf(1), local.result!!.getOrThrow().bytes)
        m.close()
    }

    @Test fun localThumbnailStillRejectsWrongIdentityAndCloseIgnoresLateImage() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        assertNull(start { m.thumbnail(file.copy(size = file.size + 1), false) }.result!!.getOrThrow().bytes)
        assertNull(p.thumbnailRemote)
        val pending = start { m.thumbnail(file, false) }
        m.close(); p.imageResult!!.complete(byteArrayOf(1), false)
        assertTrue(pending.result!!.isFailure)
    }

    @Test fun thumbnailFinishingAfterCatalogIdentityChangedCannotPublishForOldFile() {
        val p = Platform(); val m = model(p); m.finishScan(m.beginScan(), snapshot())
        val file = m.state.value.files.first()
        val pending = start { m.thumbnail(file, false) }
        val replaced = NativeFilesPageSnapshot("camera", true, false)
        replaced.addFile(file.handle, file.size + 1, file.fileName, file.captureDate, false, intArrayOf())
        assertTrue(m.finishScan(m.beginScan(), replaced))
        p.imageResult!!.complete(byteArrayOf(1), true)
        val result = pending.result!!.getOrThrow()
        assertNull(result.bytes); assertFalse(result.retryable)
        m.close()
    }
}
