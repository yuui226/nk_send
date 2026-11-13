package com.ztransfer.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Test

class TransferSpeedDisplaySamplerTest {
    @Test fun firstValidSpeedDoesNotWaitForZeroSpeedPreparation() {
        val sampler = TransferSpeedDisplaySampler()
        assertEquals(0L, sampler.sample(0L, 10_000L))
        assertEquals(0L, sampler.sample(0L, 10_100L))
        assertEquals(5_000L, sampler.sample(5_000L, 10_200L))
    }

    @Test fun fastProtocolSamplesKeepTheSpeedReadableUntilTheNextDisplayInterval() {
        val sampler = TransferSpeedDisplaySampler()
        assertEquals(5_000L, sampler.sample(5_000L, 10_000L))
        for (elapsed in 100L..500L step 100L) {
            assertEquals(5_000L, sampler.sample(5_000L + elapsed, 10_000L + elapsed))
        }
        assertEquals(5_000L, sampler.sample(5_599L, 10_599L))
        assertEquals(5_600L, sampler.sample(5_600L, 10_600L))
        assertEquals(5_600L, sampler.sample(5_700L, 10_700L))
        assertEquals(6_200L, sampler.sample(6_200L, 11_200L))
    }

    @Test fun invalidSpeedNeitherFlashesZeroNorDelaysTheNextValidSample() {
        val sampler = TransferSpeedDisplaySampler()
        assertEquals(5_000L, sampler.sample(5_000L, 10_000L))
        assertEquals(5_000L, sampler.sample(0L, 10_600L))
        assertEquals(5_000L, sampler.sample(-1L, 10_700L))
        assertEquals(7_000L, sampler.sample(7_000L, 10_701L))
    }

    @Test fun nextDownloadPublishesItsOwnFirstSpeedImmediately() {
        val previous = TransferSpeedDisplaySampler()
        assertEquals(5_000L, previous.sample(5_000L, 10_000L))
        val next = TransferSpeedDisplaySampler()
        assertEquals(0L, next.sample(0L, 10_050L))
        assertEquals(7_000L, next.sample(7_000L, 10_100L))
    }
}
