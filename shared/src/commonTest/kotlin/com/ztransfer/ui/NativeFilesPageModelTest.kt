package com.ztransfer.ui

import com.ztransfer.catalog.UNKNOWN_CAPTURE_DATE_GROUP_KEY
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.NativeOriginalIndexUpdate
import com.ztransfer.ui.screen.SharedPhotoFilterCriteria
import kotlin.coroutines.*
import kotlin.test.*

class NativeFilesPageModelTest {
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
        override fun thumbnail(file: CameraFileInfo, completion: NativeFilesThumbnailCompletion) { imageResult = completion }
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
}
