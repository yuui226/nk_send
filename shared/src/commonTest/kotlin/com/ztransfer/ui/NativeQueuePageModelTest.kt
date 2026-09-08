package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.NativePreviewPolicy
import com.ztransfer.viewmodel.TransferStatus
import kotlin.coroutines.*
import kotlin.test.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class NativeQueuePageModelTest {
    private class Platform : NativeQueuePagePlatform {
        override fun showConnectionHelp() {}
        var completion: NativeQueueActionCompletion? = null
        var imageCompletion: NativeQueueThumbnailCompletion? = null
        var command: NativeQueueCommand? = null
        var excluded = longArrayOf()
        var cancelled = 0
        override fun execute(command: NativeQueueCommand, taskId: Long, excludedTaskIds: LongArray, completion: NativeQueueActionCompletion) {
            this.command = command; excluded = excludedTaskIds; this.completion = completion
        }
        override fun thumbnail(file: CameraFileInfo, completion: NativeQueueThumbnailCompletion) { imageCompletion = completion }
        override fun fixed(value: Double, fractionDigits: Int): String = "$value/$fractionDigits"
        override fun completedSpeed(value: Float): String = "localized $value MB/s"
        override fun cancelRequests() { cancelled++ }
    }
    private class Outcome<T> { var result: Result<T>? = null }
    private fun <T> start(block: suspend () -> T): Outcome<T> = Outcome<T>().also { outcome ->
        block.startCoroutine(object : Continuation<T> {
            override val context = EmptyCoroutineContext
            override fun resumeWith(result: Result<T>) { outcome.result = result }
        })
    }
    private fun snapshot(sequence: Long = 1, history: Long = sequence, status: String = "WAITING", bytes: Long = 0,
                         connection: String = "camera", id: Long = 1) =
        NativeQueuePageSnapshot(connection, sequence, history, status == "TRANSFERING", false).also {
            assertTrue(it.addOriginal(id, 7, 1024, "DSC.JPG", "20260905T120000", true, intArrayOf(1, 2), "ZT2026-09-05",
                status, bytes, bytes / 1024f, 128, null, null, 0f))
        }

    @Test fun skippedOriginalFlagReachesTheOriginalQueueTaskWithoutInventingTiming() {
        val model = NativeQueuePageModel("camera", Platform())
        val input = NativeQueuePageSnapshot("camera", 1, 1, false, false)
        assertTrue(input.addOriginal(1, 7, 3, "DSC.JPG", null, false, intArrayOf(), null,
            "COMPLETED", 3, 1f, 0, null, null, 0f, skipped = true))
        assertTrue(model.publish(input))
        val task = model.state.value.tasks.single()
        assertTrue(task.skipped)
        assertEquals(TransferStatus.COMPLETED, task.status)
        assertEquals(3L, task.downloaded)
        assertEquals(0L, task.speed)
        assertEquals(0f, task.downloadMBps)
        assertNull(task.elapsedMs)
        assertNull(model.activeProgress.value)
    }

    @Test fun atomicSnapshotPreservesMetadataAndRejectsOldConnectionOrSequence() {
        val model = NativeQueuePageModel("camera", Platform())
        val input = snapshot(sequence = 3)
        assertTrue(model.publish(input))
        val state = model.state.value
        val task = state.tasks.single()
        assertEquals(setOf(1, 2), task.file.storageIds)
        assertEquals("ZT2026-09-05", task.destinationFolderName)
        assertTrue(task.file.isProtected)
        assertFalse(model.publish(snapshot(sequence = 2)))
        assertFalse(model.publish(snapshot(sequence = 4, connection = "other")))
        assertFalse(model.publish(input))
        assertSame(state, model.state.value)
        assertTrue(input.addOriginal(2, 9, 1, "another.JPG", null, false, intArrayOf(), null,
            "WAITING", 0, 0f, 0, null, null, 0f))
        assertEquals(1, state.tasks.size) // mutable batch builder cannot mutate an already published frame
    }

    @Test fun progressOnlyUpdateDoesNotReplaceLowFrequencyTaskList() {
        val model = NativeQueuePageModel("camera", Platform())
        model.publish(snapshot(status = "TRANSFERING"))
        val history = model.state.value
        model.publish(snapshot(sequence = 2, history = 1, status = "TRANSFERING", bytes = 512))
        assertSame(history, model.state.value)
        assertEquals(0L, history.tasks.single().downloaded)
        assertEquals(512L, model.activeProgress.value?.downloaded)
        assertEquals(0.5f, model.activeProgress.value?.fraction)
        assertEquals(128L, model.activeProgress.value?.retainedBytesPerSecond)
        model.publish(snapshot(sequence = 3, status = "COMPLETED", bytes = 1024))
        assertNull(model.activeProgress.value)
        assertEquals(TransferStatus.COMPLETED, model.state.value.tasks.single().status)
    }
    @Test fun disconnectedPagesNeverReviveStaleByteProgressFromQueuedSnapshots() {
        val model = NativeQueuePageModel("camera", Platform())
        model.setConnected(true)
        model.publish(snapshot(status = "TRANSFERING", bytes = 512))
        assertNotNull(model.activeProgress.value)
        model.setConnected(false)
        assertNull(model.activeProgress.value)
        assertFalse(model.state.value.isTransferring)
        model.publish(snapshot(sequence = 2, history = 1, status = "TRANSFERING", bytes = 768))
        assertNull(model.activeProgress.value)
        assertFalse(model.state.value.isTransferring)
        model.setConnected(true)
        model.publish(snapshot(sequence = 3, history = 1, status = "TRANSFERING", bytes = 900))
        assertEquals(900L, model.activeProgress.value?.downloaded)
        assertTrue(model.state.value.isTransferring)
    }

    @Test fun invalidDuplicateAndMultipleActiveRowsNeverReplaceGoodState() {
        val model = NativeQueuePageModel("camera", Platform())
        model.publish(snapshot())
        val state = model.state.value
        val invalid = snapshot(sequence = 2)
        assertFalse(invalid.addOriginal(1, 2, 0, "bad", null, false, intArrayOf(), null, "UNKNOWN", 0, 0f, 0, null, null, 0f))
        assertFalse(model.publish(invalid))
        val twoActive = snapshot(sequence = 3, status = "TRANSFERING")
        assertTrue(twoActive.addOriginal(2, 2, 0, "bad", null, false, intArrayOf(), null, "TRANSFERING", 0, 0f, 0, null, null, 0f))
        assertFalse(model.publish(twoActive))
        assertSame(state, model.state.value)
    }

    @Test fun removalWaitsForRealActorResultAndLiveTasksComeFromAcknowledgedSnapshot() {
        val platform = Platform(); val model = NativeQueuePageModel("camera", platform)
        model.publish(snapshot(status = "CANCELLED"))
        val result = start { model.actions.removeTask(1) }
        assertNull(result.result)
        assertEquals(NativeQueueCommand.REMOVE, platform.command)
        model.publish(NativeQueuePageSnapshot("camera", 2, 2, false, false))
        platform.completion!!.complete(true)
        assertEquals(true, result.result?.getOrThrow())
        assertTrue(model.actions.currentTasks().isEmpty())
        platform.completion!!.complete(false) // duplicate/late callbacks cannot resume twice
        assertEquals(true, result.result?.getOrThrow())
    }

    @Test fun rejectedWithdrawalDoesNotRunAnimationMarkingAndRetryKeepsExclusions() {
        val platform = Platform(); val model = NativeQueuePageModel("camera", platform)
        var marked = false
        val result = start { model.actions.withdrawTask(1); marked = true }
        platform.completion!!.complete(false)
        assertFalse(marked)
        assertIs<CancellationException>(result.result?.exceptionOrNull())
        val retry = start { model.actions.retryFailed(setOf(7, 9)) }
        assertEquals(NativeQueueCommand.RETRY_ALL, platform.command)
        assertEquals(setOf(7L, 9L), platform.excluded.toSet())
        platform.completion!!.complete(true)
        assertTrue(retry.result?.isSuccess == true)
    }

    @Test fun closingCancelsPendingWorkAndCannotBeReopenedByLateMessages() {
        val platform = Platform(); val model = NativeQueuePageModel("camera", platform)
        model.setConnected(true)
        val action = start { model.actions.removeTask(1) }
        val image = start { model.thumbnail(CameraFileInfo(1, 1, "a.JPG", null)) }
        model.close(); model.close()
        assertEquals(1, platform.cancelled)
        assertIs<CancellationException>(action.result?.exceptionOrNull())
        assertIs<CancellationException>(image.result?.exceptionOrNull())
        platform.completion!!.complete(true)
        platform.imageCompletion!!.complete(byteArrayOf(1))
        assertFalse(model.publish(snapshot()))
        model.setConnected(true)
        assertFalse(model.connected.value)
    }

    @Test fun undispatchedSynchronousAdapterRetainsAndroidClickOrdering() {
        val calls = mutableListOf<String>()
        val action: suspend () -> Unit = { calls += "withdraw" }
        CoroutineScope(Dispatchers.Unconfined).launch(start = CoroutineStart.UNDISPATCHED) {
            action(); calls += "mark"
        }
        calls += "click returned"
        assertEquals(listOf("withdraw", "mark", "click returned"), calls)
    }

    @Test fun originalThumbnailIdentityAndLanguageSelectionMatchPlatformBoundaries() {
        val file = CameraFileInfo(7, 1024, "DSC.JPG", "20260905", true, setOf(1))
        val policy = NativePreviewPolicy()
        val info = policy.originalThumbnailInfo(file)
        assertEquals(file.handle, info.handle)
        assertEquals(file.fileName, info.fileName)
        assertFalse(info.isAssociation)
        assertTrue(info.identityComplete)
        assertEquals("重试", NativeQueueTextCatalog.forLanguage("zh-Hans-CN").queue.retry)
        assertEquals(NativeQueueTextCatalog.forLanguage("zh-Hant").queue, NativeQueueTextCatalog.forLanguage("zh_TW").queue)
        assertEquals("Retry", NativeQueueTextCatalog.forLanguage("fr-FR").queue.retry)
    }
}
