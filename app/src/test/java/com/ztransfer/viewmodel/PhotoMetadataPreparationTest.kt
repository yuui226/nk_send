package com.ztransfer.viewmodel

import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class PhotoMetadataPreparationTest {
    @Test fun failingListenerDoesNotLoseOtherOwnersOfTheSameHeader() = runBlocking {
        val directory = Files.createTempDirectory("metadata-test").toFile()
        val release = CompletableDeferred<Unit>()
        val done = CompletableDeferred<PreparedPhotoMetadata<Int>>()
        val preparation = PhotoMetadataPreparation<String, Int>(this, Dispatchers.Default, directory,
            parse = { PreparedPhotoMetadata(7, PreparedPhotoMetadata.State.COMPLETE) })
        val read: suspend (Int) -> ByteArray? = { release.await(); byteArrayOf(7) }
        try {
            preparation.prepare("same", null, read, complete = { error("listener failure") })
            preparation.prepare("same", null, read, complete = { done.complete(it) })
            release.complete(Unit)
            assertEquals(7, withTimeout(5_000) { done.await() }.value)
        } finally { preparation.close(); directory.deleteRecursively() }
    }

    @Test fun slowSupplementDoesNotHoldCapturedHeaderParser() = runBlocking {
        val directory = Files.createTempDirectory("metadata-test").toFile()
        val release = CompletableDeferred<Unit>()
        val reading = CompletableDeferred<Unit>()
        val first = CompletableDeferred<PreparedPhotoMetadata<Int>>()
        val second = CompletableDeferred<PreparedPhotoMetadata<Int>>()
        val preparation = PhotoMetadataPreparation<String, Int>(this, Dispatchers.Default, directory,
            parse = { PreparedPhotoMetadata(it[0].toInt(), PreparedPhotoMetadata.State.COMPLETE) })
        try {
            preparation.prepare("missing", null, readMore = {
                reading.complete(Unit); release.await(); byteArrayOf(1)
            }, complete = { first.complete(it) })
            withTimeout(5_000) { reading.await() }
            preparation.prepare("captured", byteArrayOf(2), readMore = { error("unexpected camera read") },
                complete = { second.complete(it) })
            assertEquals(2, withTimeout(5_000) { second.await() }.value)
            assertFalse(first.isCompleted)
            release.complete(Unit)
            assertEquals(1, withTimeout(5_000) { first.await() }.value)
        } finally { preparation.close(); directory.deleteRecursively() }
    }

    @Test fun duplicateRequestsShareReadAndCacheAnAbsentExifResult() = runBlocking {
        val directory = Files.createTempDirectory("metadata-test").toFile()
        val reads = AtomicInteger()
        val release = CompletableDeferred<Unit>()
        val first = CompletableDeferred<Unit>()
        val second = CompletableDeferred<Unit>()
        val third = CompletableDeferred<Unit>()
        val preparation = PhotoMetadataPreparation<String, Int>(this, Dispatchers.Default, directory,
            parse = { PreparedPhotoMetadata(null, PreparedPhotoMetadata.State.NO_EXIF) })
        val read: suspend (Int) -> ByteArray? = { reads.incrementAndGet(); release.await(); byteArrayOf(1) }
        try {
            preparation.prepare("same", null, read, complete = { first.complete(Unit) })
            preparation.prepare("same", null, read, complete = { second.complete(Unit) })
            release.complete(Unit)
            withTimeout(5_000) { first.await(); second.await() }
            preparation.prepare("same", null, read, complete = { third.complete(Unit) })
            withTimeout(5_000) { third.await() }
            assertEquals(1, reads.get())
        } finally { preparation.close(); directory.deleteRecursively() }
    }

    @Test fun spoolIsDeletedAndCapacityFailureCompletesInsteadOfWaiting() = runBlocking {
        val directory = Files.createTempDirectory("metadata-test").toFile()
        val preparation = PhotoMetadataPreparation<String, Int>(this, Dispatchers.Default, directory,
            parse = { PreparedPhotoMetadata(it.size, PreparedPhotoMetadata.State.COMPLETE) },
            memoryLimit = 0, diskLimit = 4)
        try {
            val first = CompletableDeferred<PreparedPhotoMetadata<Int>>()
            preparation.prepare("small", byteArrayOf(1,2,3,4), readMore = { error("unexpected read") },
                complete = { first.complete(it) })
            assertEquals(4, withTimeout(5_000) { first.await() }.value)
            assertTrue(directory.walkTopDown().none { it.isFile })
            val second = CompletableDeferred<PreparedPhotoMetadata<Int>>()
            preparation.prepare("large", ByteArray(5), readMore = { error("unexpected read") },
                complete = { second.complete(it) })
            assertEquals(PreparedPhotoMetadata.State.FAILED, withTimeout(5_000) { second.await() }.state)
        } finally { preparation.close(); directory.deleteRecursively() }
    }

    @Test fun incompleteHeaderHasBoundedExpansionAndKeepsPartialFieldsOnFailure() = runBlocking {
        val directory = Files.createTempDirectory("metadata-test").toFile()
        val sizes = mutableListOf<Int>()
        val done = CompletableDeferred<PreparedPhotoMetadata<Int>>()
        val preparation = PhotoMetadataPreparation<String, Int>(this, Dispatchers.Default, directory,
            parse = { PreparedPhotoMetadata(42, PreparedPhotoMetadata.State.PARTIAL) })
        try {
            preparation.prepare("cut", byteArrayOf(1), readMore = { size -> sizes.add(size); null },
                complete = { done.complete(it) })
            val result = withTimeout(5_000) { done.await() }
            assertEquals(42, result.value)
            assertEquals(PreparedPhotoMetadata.State.FAILED, result.state)
            assertEquals(listOf(1024 * 1024), sizes)
        } finally { preparation.close(); directory.deleteRecursively() }
    }
}
