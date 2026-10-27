package com.ztransfer.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NewObjectThumbnailRetriesTest {
    @Test
    fun `old catalog files retain their normal no-thumbnail behavior`() {
        val retries = NewObjectThumbnailRetries()
        assertNull(retries.failed(9, 1_000L))
        assertTrue(retries.canAttempt(9, 1_000L))
        assertFalse(retries.isRetry(9))
        assertNull(retries.nextRetryAtMs())
    }

    @Test
    fun `new object gets only three delayed retries then may be negative cached`() {
        val retries = NewObjectThumbnailRetries()
        retries.register(1)
        assertFalse(retries.isRetry(1))
        assertEquals(1_300L, retries.failed(1, 1_000L))
        assertTrue(retries.isRetry(1))
        assertFalse(retries.canAttempt(1, 1_299L))
        assertEquals(emptySet<Int>(), retries.takeDue(1_299L))
        assertEquals(setOf(1), retries.takeDue(1_300L))
        assertTrue(retries.canAttempt(1, 1_300L))
        assertNull(retries.nextRetryAtMs())
        assertEquals(2_200L, retries.failed(1, 1_300L))
        assertEquals(setOf(1), retries.takeDue(2_200L))
        assertEquals(4_000L, retries.failed(1, 2_200L))
        assertEquals(setOf(1), retries.takeDue(4_000L))
        assertNull(retries.failed(1, 4_000L))
        assertNull(retries.failed(1, 9_000L))
        assertFalse(retries.isRetry(1))
    }

    @Test
    fun `joined failure does not consume another attempt or extend its deadline`() {
        val retries = NewObjectThumbnailRetries()
        retries.register(1)
        assertEquals(300L, retries.failed(1, 0L))
        retries.register(1)
        assertEquals(300L, retries.failed(1, 200L))
        // A visible request can start exactly at the deadline before the timer callback runs.
        assertTrue(retries.canAttempt(1, 300L))
        assertEquals(1_200L, retries.failed(1, 300L))
        assertEquals(emptySet<Int>(), retries.takeDue(301L))
        assertEquals(setOf(1), retries.takeDue(1_200L))
        assertEquals(3_000L, retries.failed(1, 1_200L))
    }

    @Test
    fun `one deadline wakes only ready handles without blocking later objects`() {
        val retries = NewObjectThumbnailRetries()
        retries.register(1)
        retries.register(2)
        retries.failed(1, 0L)
        retries.failed(2, 100L)
        assertEquals(300L, retries.nextRetryAtMs())
        assertEquals(setOf(1), retries.takeDue(300L))
        assertEquals(400L, retries.nextRetryAtMs())
        assertFalse(retries.canAttempt(2, 300L))
        assertTrue(retries.canAttempt(3, 300L))
        assertEquals(setOf(2), retries.takeDue(400L))
        assertEquals(emptySet<Int>(), retries.takeDue(400L))
    }

    @Test
    fun `success deletion and session reset discard pending retries`() {
        val retries = NewObjectThumbnailRetries()
        retries.register(1)
        retries.register(2)
        retries.failed(1, 0L)
        retries.failed(2, 0L)
        retries.remove(1)
        assertEquals(setOf(2), retries.takeDue(300L))
        assertNull(retries.failed(1, 400L))
        retries.failed(2, 400L)
        retries.clear()
        assertNull(retries.nextRetryAtMs())
        assertEquals(emptySet<Int>(), retries.takeDue(10_000L))
        assertNull(retries.failed(2, 10_000L))
        retries.register(2)
        assertFalse(retries.isRetry(2))
        assertEquals(10_300L, retries.failed(2, 10_000L))
    }
}
