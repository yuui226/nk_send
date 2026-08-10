package com.ztransfer.viewmodel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteEntryIntroPolicyTest {
    @Test
    fun introStopsAtConfiguredPlayLimit() {
        assertTrue(isRemoteEntryIntroEligible(-1))
        assertTrue(isRemoteEntryIntroEligible(0))
        assertTrue(isRemoteEntryIntroEligible(REMOTE_ENTRY_INTRO_MAX_PLAYS - 1))
        assertFalse(isRemoteEntryIntroEligible(REMOTE_ENTRY_INTRO_MAX_PLAYS))
        assertFalse(isRemoteEntryIntroEligible(REMOTE_ENTRY_INTRO_MAX_PLAYS + 1))
    }
}
