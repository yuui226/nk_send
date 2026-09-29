package com.ztransfer.filter

import com.ztransfer.lut.CubeLut
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class PhotoCubeResourceCacheTest {
    private fun table(id: String) = CubeLut(2, floatArrayOf(0f,0f,0f),
        floatArrayOf(1f,1f,1f), FloatArray(24), id)

    @Test fun queuedRecipeReloadsItsSnapshotAfterCacheEviction() {
        val weight = PhotoCubeResourceCache.Loaded(table("size")).bytes
        val cache = PhotoCubeResourceCache(weight, maxEntries = 1)
        val reads = AtomicInteger()
        val recipe = CubePhotoFilterParameters.fromSnapshot("snapshot-a", cache) {
            reads.incrementAndGet(); table("a")
        }
        val original = recipe.table
        assertSame(original, recipe.table)
        cache.acquire("snapshot-b") { table("b") }
        assertEquals("a", recipe.table.digest)
        assertEquals(2, reads.get())
        assertTrue(cache.retainedBytes <= weight)
        // Eviction does not invalidate a render that already holds its table.
        assertEquals("a", original.digest)
    }

    @Test fun sameSnapshotLoadsOnceAndUnrelatedHitsDoNotWaitForDiskRead() {
        val cache = PhotoCubeResourceCache()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val reads = AtomicInteger()
        val pool = Executors.newFixedThreadPool(3)
        try {
            cache.seed("fast", table("fast"))
            val slow = pool.submit<PhotoCubeResourceCache.Loaded> {
                cache.acquire("slow") {
                    reads.incrementAndGet(); entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS)); table("slow")
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val duplicate = pool.submit<PhotoCubeResourceCache.Loaded> {
                cache.acquire("slow") { reads.incrementAndGet(); table("slow") }
            }
            val fast = pool.submit<PhotoCubeResourceCache.Loaded> {
                cache.acquire("fast") { error("cache hit reread") }
            }
            assertEquals("fast", fast.get(5, TimeUnit.SECONDS).table.digest)
            release.countDown()
            assertSame(slow.get(5, TimeUnit.SECONDS), duplicate.get(5, TimeUnit.SECONDS))
            assertEquals(1, reads.get())
        } finally { release.countDown(); pool.shutdownNow() }
    }
}
