package com.ztransfer.ui.screen

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class PhotoEffectsPreviewCacheTest {
    @Test(timeout = 5_000)
    fun closingAnIntermediateDoesNotStrandTheNextFrameBehindTheGlobalRenderLock() = runBlocking {
        val renderLock = Mutex()
        val intermediate = PhotoEffectsPreviewCache<String>(renderLock)
        val oldFrame = PhotoEffectsPreviewCache<String>(renderLock)
        val latestFrame = PhotoEffectsPreviewCache<String>(renderLock)
        val started = CompletableDeferred<Unit>()
        try {
            val oldRequest = async {
                oldFrame.getOrRender {
                    intermediate.getOrRender(serializeWithOtherPreviews = false) {
                        started.complete(Unit)
                        awaitCancellation()
                    }
                }
            }
            started.await()
            intermediate.close()

            assertEquals("latest", withTimeout(1_500) { latestFrame.getOrRender { "latest" } })
            assertTrue(runCatching { oldRequest.await() }.exceptionOrNull() is CancellationException)
        } finally {
            intermediate.close()
            oldFrame.close()
            latestFrame.close()
        }
    }

    @Test(timeout = 5_000)
    fun aClosedCacheDoesNotStartAnotherRender() = runBlocking {
        val cache = PhotoEffectsPreviewCache<String>(Mutex())
        cache.close()
        var calls = 0
        val result = runCatching { cache.getOrRender { calls++; "unexpected" } }
        assertTrue(result.exceptionOrNull() is CancellationException)
        assertEquals(0, calls)
    }

    @Test(timeout = 5_000)
    fun cancellingAnAwaiterPreservesWorkForTheNextAwaiter() = runBlocking {
        val cache = PhotoEffectsPreviewCache<String>(Mutex())
        val started = CompletableDeferred<Unit>()
        val complete = CompletableDeferred<String>()
        val calls = AtomicInteger()
        try {
            val first = async {
                cache.getOrRender {
                    calls.incrementAndGet()
                    started.complete(Unit)
                    complete.await()
                }
            }
            started.await()
            first.cancelAndJoin()
            val next = async(start = CoroutineStart.UNDISPATCHED) {
                cache.getOrRender { calls.incrementAndGet(); "duplicate" }
            }
            complete.complete("shared")
            assertEquals("shared", next.await())
            assertEquals(1, calls.get())
        } finally {
            cache.close()
        }
    }

    @Test(timeout = 5_000)
    fun aReactivatedObsoleteTargetRetriesWithCurrentDemand() = runBlocking {
        val cache = PhotoEffectsPreviewCache<String>(Mutex())
        val calls = AtomicInteger()
        var obsolete = false
        try {
            val result = cache.getOrRender(isObsolete = { obsolete }) { cancelled ->
                if (calls.incrementAndGet() == 1) {
                    obsolete = true
                    assertTrue(cancelled())
                    obsolete = false
                    throw CancellationException("Obsolete filter selected again")
                }
                "current"
            }
            assertEquals("current", result)
            assertEquals(2, calls.get())
        } finally {
            cache.close()
        }
    }

    @Test(timeout = 5_000)
    fun aNewRequestJoiningAnOldCancelledRenderRetriesWithItsOwnDependencies() = runBlocking {
        val cache = PhotoEffectsPreviewCache<String>(Mutex())
        val started = CompletableDeferred<Unit>()
        val cancelOld = CompletableDeferred<Unit>()
        val newCalls = AtomicInteger()
        try {
            val oldRequest = async {
                cache.getOrRender {
                    started.complete(Unit)
                    cancelOld.await()
                    throw CancellationException("Old intermediate closed")
                }
            }
            started.await()
            oldRequest.cancelAndJoin()
            val next = async(start = CoroutineStart.UNDISPATCHED) {
                cache.getOrRender { newCalls.incrementAndGet(); "new dependency" }
            }
            cancelOld.complete(Unit)
            assertEquals("new dependency", next.await())
            assertEquals(1, newCalls.get())
        } finally {
            cache.close()
        }
    }

    @Test(timeout = 5_000)
    fun anUnrelatedRenderCancellationIsNotRetriedInALoop() = runBlocking {
        val cache = PhotoEffectsPreviewCache<String>(Mutex())
        val calls = AtomicInteger()
        try {
            val result = runCatching {
                cache.getOrRender {
                    calls.incrementAndGet()
                    throw CancellationException("Dependency unavailable")
                }
            }
            assertTrue(result.exceptionOrNull() is CancellationException)
            assertEquals(1, calls.get())
            assertEquals("recovered", cache.getOrRender { "recovered" })
        } finally {
            cache.close()
        }
    }
}
