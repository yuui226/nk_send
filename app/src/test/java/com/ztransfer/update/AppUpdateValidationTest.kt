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

    @Test
    fun fixedReleaseInstallsOnlyWhenNewerOrUnreadable() {
        assertTrue(isFixedReleaseInstallable(actualVersion = null, installedVersion = 68))
        assertTrue(isFixedReleaseInstallable(actualVersion = 69, installedVersion = 68))
        assertFalse(isFixedReleaseInstallable(actualVersion = 68, installedVersion = 68))
        assertFalse(isFixedReleaseInstallable(actualVersion = 67, installedVersion = 68))
    }

    @Test
    fun fixedReleaseRejectsNonApkPayload() {
        assertTrue(hasZipMagic(byteArrayOf(0x50, 0x4B, 0x03, 0x04, 0x00)))
        assertFalse(hasZipMagic(byteArrayOf(0x3C, 0x68, 0x74, 0x6D)))
        assertFalse(hasZipMagic(byteArrayOf(0x50, 0x4B)))
    }
}
