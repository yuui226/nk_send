package com.ztransfer

import org.junit.Assert.assertEquals
import org.junit.Test

class DistributionConfigTest {
    @Test
    fun channelConfigurationMatchesApplicationIdAndSelfUpdatePolicy() {
        when (BuildConfig.DISTRIBUTION_CHANNEL) {
            "direct" -> {
                assertEquals("com.ztransfer", BuildConfig.APPLICATION_ID)
                assertEquals(true, BuildConfig.ENABLE_SELF_UPDATE)
            }

            "play" -> {
                assertEquals("com.ztransfer.play", BuildConfig.APPLICATION_ID)
                assertEquals(false, BuildConfig.ENABLE_SELF_UPDATE)
            }

            else -> error("Unknown distribution channel: ${BuildConfig.DISTRIBUTION_CHANNEL}")
        }
    }
}
