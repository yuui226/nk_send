package com.ztransfer

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainNavigationPolicyTest {
    @Test
    fun filesAndTransferScreensPreferHighThroughputTransfers() {
        assertTrue(shouldPreferHighThroughputTransfers(Screen.Files.route))
        assertTrue(shouldPreferHighThroughputTransfers(Screen.Transfer.route))
    }

    @Test
    fun otherScreensKeepInteractiveTransferPolicy() {
        assertFalse(shouldPreferHighThroughputTransfers(Screen.Home.route))
        assertFalse(shouldPreferHighThroughputTransfers(Screen.Remote.route))
        assertFalse(shouldPreferHighThroughputTransfers(null))
    }

    @Test
    fun notificationHintAppearsOnlyOnFirstAndroid13PlusLaunch() {
        assertTrue(
            shouldShowFirstLaunchNotificationHint(
                sdkInt = 33,
                firstLaunch = true,
                permissionGranted = false
            )
        )
        assertFalse(
            shouldShowFirstLaunchNotificationHint(
                sdkInt = 32,
                firstLaunch = true,
                permissionGranted = false
            )
        )
        assertFalse(
            shouldShowFirstLaunchNotificationHint(
                sdkInt = 35,
                firstLaunch = true,
                permissionGranted = true
            )
        )
        assertFalse(
            shouldShowFirstLaunchNotificationHint(
                sdkInt = 35,
                firstLaunch = false,
                permissionGranted = false
            )
        )
    }
}
