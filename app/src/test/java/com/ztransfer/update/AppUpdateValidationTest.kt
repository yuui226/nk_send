package com.ztransfer.update

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdateValidationTest {
    @Test
    fun acceptsExpectedVersion() {
        assertTrue(isDownloadedVersionAcceptable(actualVersion = 20L, expectedVersion = 20))
    }

    @Test
    fun rejectsOnlyExplicitVersionMismatch() {
        assertFalse(isDownloadedVersionAcceptable(actualVersion = 19L, expectedVersion = 20))
        assertFalse(isDownloadedVersionAcceptable(actualVersion = 21L, expectedVersion = 20))
    }

    @Test
    fun acceptsWhenHarmonyCannotReadArchiveMetadata() {
        assertTrue(isDownloadedVersionAcceptable(actualVersion = null, expectedVersion = 20))
    }
}
