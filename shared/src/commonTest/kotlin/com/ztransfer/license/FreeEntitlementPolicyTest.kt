package com.ztransfer.license

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FreeEntitlementPolicyTest {
    @Test
    fun productLimitsKeepTheirEstablishedValues() {
        assertEquals(25, FREE_DAILY_TRANSFER_LIMIT)
        assertEquals(400L * 1024L * 1024L, FREE_MAX_FILE_BYTES)
        assertEquals(3L * 60_000L, FREE_REMOTE_DAILY_MS)
    }

    @Test
    fun freeTransferQuotaStopsAtTheDailyBoundary() {
        assertEquals(25, dailyTransferQuotaRemaining(isPro = false, transfersDoneToday = 0))
        assertEquals(1, dailyTransferQuotaRemaining(isPro = false, transfersDoneToday = 24))
        assertEquals(0, dailyTransferQuotaRemaining(isPro = false, transfersDoneToday = 25))
        assertEquals(0, dailyTransferQuotaRemaining(isPro = false, transfersDoneToday = 26))

        assertFalse(hasReachedDailyTransferLimit(isPro = false, transfersDoneToday = 24))
        assertTrue(hasReachedDailyTransferLimit(isPro = false, transfersDoneToday = 25))
        assertTrue(hasReachedDailyTransferLimit(isPro = false, transfersDoneToday = 26))
    }

    @Test
    fun fileExactlyAtTheFreeSizeLimitRemainsAllowed() {
        assertFalse(exceedsFreeFileSizeLimit(isPro = false, sizeBytes = FREE_MAX_FILE_BYTES))
        assertTrue(
            exceedsFreeFileSizeLimit(
                isPro = false,
                sizeBytes = FREE_MAX_FILE_BYTES + 1L,
            ),
        )
        assertTrue(exceedsFreeFileSizeLimit(isPro = false, sizeBytes = 0xFFFF_FFFFL))
    }

    @Test
    fun freeRemoteTimeStopsAtZero() {
        assertEquals(
            FREE_REMOTE_DAILY_MS,
            dailyRemoteTimeRemainingMs(isPro = false, usedTodayMs = 0L),
        )
        assertEquals(1L, dailyRemoteTimeRemainingMs(false, FREE_REMOTE_DAILY_MS - 1L))
        assertEquals(0L, dailyRemoteTimeRemainingMs(false, FREE_REMOTE_DAILY_MS))
        assertEquals(0L, dailyRemoteTimeRemainingMs(false, FREE_REMOTE_DAILY_MS + 1L))
    }

    @Test
    fun proMembershipBypassesEveryFreeLimit() {
        assertEquals(
            Int.MAX_VALUE,
            dailyTransferQuotaRemaining(isPro = true, transfersDoneToday = Int.MAX_VALUE),
        )
        assertFalse(hasReachedDailyTransferLimit(isPro = true, transfersDoneToday = Int.MAX_VALUE))
        assertFalse(exceedsFreeFileSizeLimit(isPro = true, sizeBytes = Long.MAX_VALUE))
        assertEquals(
            Long.MAX_VALUE,
            dailyRemoteTimeRemainingMs(isPro = true, usedTodayMs = Long.MAX_VALUE),
        )
    }
}
