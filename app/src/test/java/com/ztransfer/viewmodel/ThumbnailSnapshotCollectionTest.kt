package com.ztransfer.viewmodel

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test

class ThumbnailSnapshotCollectionTest {
    @Test
    fun `new file batches do not cancel the thumbnail request already in progress`() = runBlocking {
        val snapshots = MutableStateFlow(listOf(1))
        val firstStarted = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val latestProcessed = CompletableDeferred<Unit>()
        val processed = mutableListOf<List<Int>>()

        val job = launch {
            collectThumbnailSnapshotsSequentially(snapshots) { snapshot ->
                processed += snapshot
                if (snapshot == listOf(1)) {
                    firstStarted.complete(Unit)
                    releaseFirst.await()
                }
                if (snapshot == listOf(1, 2, 3)) latestProcessed.complete(Unit)
            }
        }

        firstStarted.await()
        snapshots.value = listOf(1, 2)
        snapshots.value = listOf(1, 2, 3)
        releaseFirst.complete(Unit)
        withTimeout(1_000) { latestProcessed.await() }
        job.cancelAndJoin()

        assertEquals(listOf(listOf(1), listOf(1, 2, 3)), processed)
    }
}
