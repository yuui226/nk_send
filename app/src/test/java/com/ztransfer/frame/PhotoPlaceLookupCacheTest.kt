package com.ztransfer.frame

import com.ztransfer.location.PhotoPlaceLookupCache
import com.ztransfer.location.PhotoPlaceLookupResult

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class PhotoPlaceLookupCacheTest {
    @Test fun cancelledPreviewDoesNotBlockAnImmediateExport() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        val entered = CompletableDeferred<Unit>()
        val never = CompletableDeferred<Unit>()
        val trace = mutableListOf<String>()
        val preview = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("same", trace = trace::add) {
                entered.complete(Unit)
                never.await()
                PhotoPlaceLookupResult.Empty
            }
        }
        entered.await()
        preview.cancelAndJoin()
        var requests = 0
        assertEquals("city", cache.resolve("same") {
            requests++
            PhotoPlaceLookupResult.Found("city")
        })
        assertEquals(1, requests)
        assertTrue(trace.contains("placeLookup=cancelled"))
        assertFalse(trace.contains("placeLookup=empty"))
    }

    @Test fun actualRequestTimeoutDoesNotCreateANegativeCache() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        val trace = mutableListOf<String>()
        assertNull(cache.resolve("same", timeoutMillis = 20L, trace = trace::add) {
            CompletableDeferred<Unit>().await()
            PhotoPlaceLookupResult.Empty
        })
        assertTrue(trace.contains("placeLookup=timeout"))
        assertEquals("retried", cache.resolve("same") { PhotoPlaceLookupResult.Found("retried") })
    }

    @Test fun queueWaitDoesNotConsumeTheNextRequestsBudget() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        val firstEntered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("first", timeoutMillis = 1_000L) {
                firstEntered.complete(Unit)
                release.await()
                PhotoPlaceLookupResult.Found("first")
            }
        }
        firstEntered.await()
        var secondRequests = 0
        val second = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("second", timeoutMillis = 20L) {
                secondRequests++
                PhotoPlaceLookupResult.Found("second")
            }
        }
        delay(60L) // Deliberately longer than the second request's own budget.
        assertFalse(second.isCompleted)
        assertEquals(0, secondRequests)
        release.complete(Unit)
        assertEquals("first", first.await())
        assertEquals("second", withTimeout(1_000L) { second.await() })
        assertEquals(1, secondRequests)
    }

    @Test fun cancelledWaiterNeverStartsItsBackend() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        val release = CompletableDeferred<Unit>()
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("first") { release.await(); PhotoPlaceLookupResult.Found("first") }
        }
        var calls = 0
        val waiting = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("second") { calls++; PhotoPlaceLookupResult.Empty }
        }
        waiting.cancelAndJoin()
        release.complete(Unit)
        first.await()
        assertEquals(0, calls)
        assertEquals("second", cache.resolve("second") { PhotoPlaceLookupResult.Found("second") })
    }

    @Test fun concurrentSameCoordinateUsesTheCompletedResult() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        val release = CompletableDeferred<Unit>()
        var calls = 0
        val first = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("same") { calls++; release.await(); PhotoPlaceLookupResult.Found("city") }
        }
        val second = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("same") { calls++; PhotoPlaceLookupResult.Empty }
        }
        release.complete(Unit)
        assertEquals("city", first.await())
        assertEquals("city", second.await())
        assertEquals(1, calls)
    }

    @Test fun cachedSuccessDoesNotWaitForAnUnrelatedRequest() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        cache.resolve("ready") { PhotoPlaceLookupResult.Found("city") }
        val release = CompletableDeferred<Unit>()
        val other = async(start = CoroutineStart.UNDISPATCHED) {
            cache.resolve("other") { release.await(); PhotoPlaceLookupResult.Empty }
        }
        try {
            assertEquals("city", withTimeout(100L) {
                cache.resolve("ready") { fail("Unexpected backend"); PhotoPlaceLookupResult.Empty }
            })
        } finally { release.complete(Unit); other.await() }
    }

    @Test fun successfulEntriesExpireUsingTheInjectedClock() = runBlocking {
        var now = 0L
        val cache = PhotoPlaceLookupCache<String>({ now })
        var calls = 0
        suspend fun lookup() = cache.resolve("same") { calls++; PhotoPlaceLookupResult.Found("city") }
        assertEquals("city", lookup())
        now = 86_399_999L
        assertEquals("city", lookup())
        assertEquals(1, calls)
        now = 86_400_000L
        assertEquals("city", lookup())
        assertEquals(2, calls)
    }

    @Test fun explicitEmptyAndErrorHaveDifferentShortBackoffs() = runBlocking {
        var now = 0L
        val cache = PhotoPlaceLookupCache<String>({ now })
        val trace = mutableListOf<String>()
        cache.resolve("empty") { PhotoPlaceLookupResult.Empty }
        cache.resolve("error") { PhotoPlaceLookupResult.Error }
        var calls = 0
        suspend fun retry(key: String) = cache.resolve(key, trace = trace::add) {
            calls++
            PhotoPlaceLookupResult.Found(key)
        }
        now = 4_999L
        assertNull(retry("empty"))
        assertNull(retry("error"))
        assertEquals(0, calls)
        assertTrue(trace.contains("placeLookup=cache-empty"))
        assertTrue(trace.contains("placeLookup=cache-error"))
        now = 5_000L
        assertEquals("error", retry("error"))
        assertNull(retry("empty"))
        now = 15_000L
        assertEquals("empty", retry("empty"))
        assertEquals(2, calls)
    }

    @Test fun unavailableProviderOrNetworkIsNotCached() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        val trace = mutableListOf<String>()
        assertNull(cache.resolve("same", trace = trace::add) {
            PhotoPlaceLookupResult.Unavailable("provider-missing")
        })
        assertEquals("city", cache.resolve("same") { PhotoPlaceLookupResult.Found("city") })
        assertTrue(trace.contains("placeLookup=provider-missing"))
    }

    @Test fun backendExceptionsAreBoundedWithoutLoggingSensitiveMessages() = runBlocking {
        var now = 0L
        val cache = PhotoPlaceLookupCache<String>({ now })
        val trace = mutableListOf<String>()
        assertNull(cache.resolve("30.25,120.15", trace = trace::add) {
            throw IllegalStateException("private coordinates 30.25,120.15")
        })
        assertTrue(trace.any { it.contains("type=IllegalStateException") })
        assertTrue(trace.none { it.contains("30.25") || it.contains("private") })
        now = 5_000L
        assertEquals("city", cache.resolve("30.25,120.15") { PhotoPlaceLookupResult.Found("city") })
    }

    @Test fun cancellationThrownByBackendIsNeverSwallowedOrCached() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L })
        try {
            cache.resolve("same") { throw CancellationException("replaced") }
            fail("Cancellation must propagate")
        } catch (_: CancellationException) { }
        assertEquals("city", cache.resolve("same") { PhotoPlaceLookupResult.Found("city") })
    }

    @Test fun cacheRetainsOnlyTheConfiguredNumberOfEntries() = runBlocking {
        val cache = PhotoPlaceLookupCache<String>({ 0L }, maxEntries = 2)
        cache.resolve("a") { PhotoPlaceLookupResult.Found("a") }
        cache.resolve("b") { PhotoPlaceLookupResult.Found("b") }
        cache.resolve("a") { fail("Expected hit"); PhotoPlaceLookupResult.Empty }
        cache.resolve("c") { PhotoPlaceLookupResult.Found("c") }
        var requests = 0
        assertEquals("b-new", cache.resolve("b") { requests++; PhotoPlaceLookupResult.Found("b-new") })
        assertEquals(1, requests)
    }
}
