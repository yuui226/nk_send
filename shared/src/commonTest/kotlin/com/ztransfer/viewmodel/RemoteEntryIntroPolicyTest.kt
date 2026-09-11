package com.ztransfer.viewmodel

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

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
